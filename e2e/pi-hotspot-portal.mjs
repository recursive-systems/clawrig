import { chromium } from "@playwright/test";

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
}

function escCssAttr(input) {
  return input.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

async function run() {
  const hotspotBaseUrl = process.env.PI_E2E_HOTSPOT_BASE_URL || "http://192.168.4.1";
  const ssid = requireEnv("TEST_WIFI_SSID");
  const wifiPass = requireEnv("TEST_WIFI_PASS");

  const result = {
    ok: true,
    baseUrl: hotspotBaseUrl,
    finalUrl: "",
    steps: []
  };

  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  try {
    await page.goto(`${hotspotBaseUrl}/portal`, { waitUntil: "domcontentloaded", timeout: 60_000 });
    result.steps.push({ step: "goto_portal", status: "ok" });

    let ssidInput = page.locator(`input[type="radio"][name="ssid"][value="${escCssAttr(ssid)}"]`);
    let ssidFound = false;

    for (let i = 0; i < 12; i++) {
      if ((await ssidInput.count()) > 0) {
        ssidFound = true;
        break;
      }

      const rescanBtn = page.getByRole("button", { name: /Rescan networks/i });
      if ((await rescanBtn.count()) > 0 && (await rescanBtn.first().isVisible())) {
        await rescanBtn.first().click({ timeout: 10_000, noWaitAfter: true });
      } else {
        await page.reload({ waitUntil: "domcontentloaded", timeout: 30_000 });
      }

      await page.waitForTimeout(2_000);
      ssidInput = page.locator(`input[type="radio"][name="ssid"][value="${escCssAttr(ssid)}"]`);
    }

    if (!ssidFound) {
      throw new Error(`Target SSID not found on hotspot portal: ${ssid}`);
    }

    await ssidInput.first().check({ timeout: 15_000 });
    result.steps.push({ step: "select_ssid", status: "ok" });

    const pwdInput = page.locator("input[type=password]").first();
    await pwdInput.waitFor({ state: "visible", timeout: 15_000 });
    await pwdInput.fill(wifiPass, { timeout: 15_000 });
    result.steps.push({ step: "fill_wifi_password", status: "ok" });

    const portalForm = page.locator("form.wifi-form").first();
    if ((await portalForm.count()) === 0) {
      throw new Error("Portal connect form not found.");
    }

    await portalForm.evaluate((form) => form.requestSubmit());
    result.steps.push({ step: "portal_connect", status: "ok" });

    await page.getByRole("button", { name: /^Finish$/i }).first().click({ timeout: 15_000 });
    result.steps.push({ step: "portal_finish", status: "ok" });

    // Success here is either an explicit station/IP status before teardown or
    // the hotspot going away after Finish.
    let handoffStatus = null;
    let handoffObserved = false;

    for (let i = 0; i < 45; i++) {
      const status = await page.evaluate(async (base) => {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 3000);

        try {
          const r = await fetch(`${base}/portal/status.json`, {
            cache: "no-store",
            signal: controller.signal
          });
          if (!r.ok) return { kind: "http_error", code: r.status };
          return { kind: "ok", payload: await r.json() };
        } catch (error) {
          return { kind: "network_error", message: String(error) };
        } finally {
          clearTimeout(timer);
        }
      }, hotspotBaseUrl);

      if (status.kind === "ok") {
        handoffStatus = status.payload;
        if (handoffStatus.last_error) {
          throw new Error(`Portal handoff failed: ${handoffStatus.last_error}`);
        }

        if (handoffStatus.mode === "station" && handoffStatus.ip) {
          handoffObserved = true;
          break;
        }
      } else if (status.kind === "network_error") {
        handoffObserved = true;
        handoffStatus = status;
        break;
      }

      await page.waitForTimeout(2_000);
    }

    if (!handoffObserved) {
      throw new Error(`Hotspot portal never handed off to station mode or disconnected. Last status: ${JSON.stringify(handoffStatus)}`);
    }

    result.steps.push({ step: "portal_handoff", status: "ok", detail: JSON.stringify(handoffStatus) });
    result.finalUrl = page.url();
  } catch (error) {
    result.ok = false;
    result.error = error.message;
    throw error;
  } finally {
    const screenshotPath = process.env.PI_E2E_HOTSPOT_SCREENSHOT || ".tmp/pi-hotspot-portal-final.png";
    await page.screenshot({ path: screenshotPath, fullPage: true }).catch(() => {});
    await browser.close();
    console.log(JSON.stringify(result, null, 2));
  }
}

run().catch((error) => {
  console.error(error);
  process.exit(1);
});
