import { chromium } from "@playwright/test";

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
}

function escRegex(input) {
  return input.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function escCssAttr(input) {
  return input.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

async function pushLiveEvent(page, event, payload = {}, timeoutMs = 15_000) {
  const started = Date.now();

  while (Date.now() - started < timeoutMs) {
    const pushed = await page.evaluate(
      ({ event, payload }) => {
        try {
          const main = document.querySelector("[data-phx-main]");
          if (!main || !window.liveSocket || !window.liveSocket.main) return false;
          const view = window.liveSocket.main.getViewByEl(main);
          if (!view) return false;
          view.pushEvent(event, payload || {});
          return true;
        } catch (_err) {
          return false;
        }
      },
      { event, payload }
    );

    if (pushed) {
      return true;
    }

    await page.waitForTimeout(250);
  }

  return false;
}

async function clickWhenEnabled(locator, timeoutMs = 30_000) {
  const started = Date.now();

  while (Date.now() - started < timeoutMs) {
    if ((await locator.count()) > 0) {
      const first = locator.first();
      if ((await first.isVisible()) && (await first.isEnabled())) {
        await first.click({ timeout: 10_000 });
        return true;
      }
    }

    await new Promise((resolve) => setTimeout(resolve, 500));
  }

  return false;
}

async function clickIfVisible(locator, step, steps) {
  if ((await locator.count()) > 0 && (await locator.first().isVisible())) {
    await locator.first().click({ timeout: 15_000 });
    steps.push({ step, status: "ok" });
    return true;
  }

  steps.push({ step, status: "skip" });
  return false;
}

async function loginToDashboard(page, baseUrl, dashboardPassword, steps) {
  if (!dashboardPassword) {
    throw new Error("Dashboard password missing for post-setup login.");
  }

  await page.goto(`${baseUrl}/login`, { waitUntil: "domcontentloaded", timeout: 30_000 });

  const loginPassword = page.locator("#login-password").first();
  await loginPassword.waitFor({ state: "visible", timeout: 30_000 });
  await loginPassword.fill(dashboardPassword, { timeout: 15_000 });
  await page.getByRole("button", { name: /Sign in/i }).first().click({ timeout: 15_000 });
  steps.push({ step: "dashboard_login", status: "ok" });

  await page.getByText("Overview").first().waitFor({ state: "visible", timeout: 30_000 });
}

async function waitForTelegramOwnerLink(page, timeoutSecs, result) {
  const qr = page.locator("#tg-qr-bot").first();
  await qr.waitFor({ state: "visible", timeout: 30_000 });
  const deepLink = await qr.getAttribute("data-url");

  if (!deepLink) {
    throw new Error("Telegram deep link not found on wizard page.");
  }

  result.telegram_deep_link = deepLink;
  console.log(`[telegram-assist] deep_link=${deepLink}`);

  const deadline = Date.now() + timeoutSecs * 1000;
  let linked = false;

  while (Date.now() < deadline) {
    const connectedHeading = page.getByRole("heading", { name: /^Connected$/i }).first();
    if ((await connectedHeading.count()) > 0 && (await connectedHeading.isVisible())) {
      linked = true;
      break;
    }

    const checkNowBtn = page.getByRole("button", { name: /^Check now$/i }).first();
    if ((await checkNowBtn.count()) > 0 && (await checkNowBtn.isVisible()) && (await checkNowBtn.isEnabled())) {
      await checkNowBtn.click({ timeout: 10_000, force: true });
    }

    await page.waitForTimeout(3_000);
  }

  if (!linked) {
    throw new Error(`Timed out waiting for Telegram /start after ${timeoutSecs}s. Open the deep link, tap Start, then retry.`);
  }

  result.steps.push({ step: "telegram_owner_link", status: "ok" });
}

async function waitForSetupReady(page, steps, baseUrl) {
  let retriedPortalFinish = false;

  for (let i = 0; i < 30; i++) {
    const url = page.url();

    if (url.includes("/portal")) {
      const finishBtn = page.getByRole("button", { name: /^Finish$/i });
      if (!retriedPortalFinish && (await finishBtn.count()) > 0 && (await finishBtn.first().isVisible())) {
        await finishBtn.first().click({ timeout: 10_000, noWaitAfter: true }).catch(() => {});
        steps.push({ step: "portal_finish_retry", status: "ok", detail: `attempt=${i + 1}` });
        retriedPortalFinish = true;
      }

      await page.waitForTimeout(2_000);
      await page.goto(`${baseUrl}/setup`, { waitUntil: "domcontentloaded", timeout: 10_000 }).catch(() => {});
      continue;
    }

    const hasWifiSetupHeading = (await page.getByRole("heading", { name: /Wi-Fi Setup/i }).count()) > 0;
    if (hasWifiSetupHeading && !retriedPortalFinish) {
      await page.goto(`${baseUrl}/portal`, { waitUntil: "domcontentloaded", timeout: 10_000 }).catch(() => {});
      const finishBtn = page.getByRole("button", { name: /^Finish$/i });
      if ((await finishBtn.count()) > 0 && (await finishBtn.first().isVisible())) {
        await finishBtn.first().click({ timeout: 10_000, noWaitAfter: true }).catch(() => {});
        steps.push({ step: "portal_finish_retry", status: "ok", detail: `attempt=${i + 1}` });
      } else {
        steps.push({ step: "portal_finish_retry", status: "skip", detail: `attempt=${i + 1}` });
      }
      retriedPortalFinish = true;
      await page.waitForTimeout(2_000);
      await page.goto(`${baseUrl}/setup`, { waitUntil: "domcontentloaded", timeout: 10_000 }).catch(() => {});
      continue;
    }

    const hasPreflight = (await page.locator(".wizard-footer").getByRole("button", { name: "Continue", exact: true }).count()) > 0;
    const hasPreflightHeading = (await page.getByRole("heading", { name: /You're online|Connectivity|No internet/i }).count()) > 0;
    const hasProviderCards = (await page.locator("#provider-panel .provider-type-card").count()) > 0;
    const hasApiLabel = (await page.getByLabel(/API key/i).count()) > 0;
    const hasCompatInputs = (await page.locator("input[name*=api], input[id*=api]").count()) > 0;

    if (hasPreflight || hasPreflightHeading || hasProviderCards || hasApiLabel || hasCompatInputs) {
      steps.push({ step: "setup_ready", status: "ok", detail: `attempt=${i + 1}` });
      return;
    }

    await page.waitForTimeout(1_000);
  }

  const h = await page.locator("h1, h2").first().innerText().catch(() => "(none)");
  throw new Error(`Setup did not reach expected panels within timeout; first heading: ${h}`);
}

async function run() {
  const host = requireEnv("TEST_PI_HOST");
  const ssid = requireEnv("TEST_WIFI_SSID");
  const wifiPass = requireEnv("TEST_WIFI_PASS");
  const providerApiKey = requireEnv("TEST_PROVIDER_API_KEY");
  const flowMode = (process.env.PI_E2E_FLOW_MODE || "full").toLowerCase();

  const providerMode = (process.env.PI_E2E_PROVIDER_MODE || "openai_api_key").toLowerCase();
  const requireHandoffReady = (process.env.PI_E2E_REQUIRE_HANDOFF_READY || "1") !== "0";
  const providerBaseUrl = process.env.TEST_PROVIDER_BASE_URL || "";
  const providerModelId = process.env.TEST_PROVIDER_MODEL_ID || "";
  const providerDisplayName = process.env.TEST_PROVIDER_DISPLAY_NAME || "";

  const dashboardPassword = process.env.TEST_DASHBOARD_PASSWORD || "ClawRig123!";
  const telegramMode = (process.env.PI_E2E_TELEGRAM_MODE || "skip").toLowerCase();
  const telegramAssistTimeoutSecs = Number(process.env.PI_E2E_TELEGRAM_ASSIST_TIMEOUT_SECS || "600");
  const telegramSendTest =
    (process.env.PI_E2E_TELEGRAM_SEND_TEST || (telegramMode === "assist_link" ? "1" : "0")) !== "0";
  const tailscaleMode = (process.env.PI_E2E_TAILSCALE_MODE || "off").toLowerCase();
  const telegramBotToken = process.env.TEST_TELEGRAM_BOT_TOKEN || "";
  const tailscaleAuthKey = process.env.TEST_TAILSCALE_AUTH_KEY || "";
  const baseUrl = `http://${host}`;

  const result = {
    ok: true,
    baseUrl,
    finalUrl: "",
    mode: { provider: providerMode, telegram: telegramMode, tailscale: tailscaleMode },
    steps: []
  };

  if (providerMode === "compatible") {
    if (!providerBaseUrl) {
      throw new Error("PI_E2E_PROVIDER_MODE=compatible requires TEST_PROVIDER_BASE_URL.");
    }
    if (!providerModelId) {
      throw new Error("PI_E2E_PROVIDER_MODE=compatible requires TEST_PROVIDER_MODEL_ID.");
    }
  }

  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  try {
    if (flowMode === "full") {
      await page.goto(`${baseUrl}/portal`, { waitUntil: "domcontentloaded", timeout: 60_000 });
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
          // On real Pi portal, rescan may patch LiveView state without navigation.
          await rescanBtn.first().click({ timeout: 10_000, noWaitAfter: true });
        } else {
          await page.reload({ waitUntil: "domcontentloaded", timeout: 30_000 });
        }

        await page.waitForTimeout(2_000);
        ssidInput = page.locator(`input[type="radio"][name="ssid"][value="${escCssAttr(ssid)}"]`);
      }

      if (!ssidFound) {
        throw new Error(`Target SSID not found on portal: ${ssid}`);
      }

      await ssidInput.first().check({ timeout: 15_000 });
      result.steps.push({ step: "select_ssid", status: "ok" });

      const pwdInput = page.locator("input[type=password]");
      if ((await pwdInput.count()) === 0) {
        throw new Error("No Wi-Fi password input found on portal.");
      }

      const portalPwd = pwdInput.first();
      await portalPwd.fill(wifiPass, { timeout: 15_000 });

      const pwdEcho = await portalPwd.inputValue();
      if (pwdEcho !== wifiPass) {
        throw new Error(`Wi-Fi password input mismatch before submit (len=${pwdEcho.length}).`);
      }
      result.steps.push({ step: "fill_wifi_password", status: "ok" });

      const portalForm = page.locator("form.wifi-form").first();
      if ((await portalForm.count()) === 0) {
        throw new Error("Portal connect form not found.");
      }

      await portalForm.evaluate((form) => form.requestSubmit());
      result.steps.push({ step: "portal_connect", status: "ok" });
      await page.getByRole("button", { name: /^Finish$/i }).first().click({ timeout: 15_000 });
      result.steps.push({ step: "portal_finish", status: "ok" });

      // Wait for portal handoff to reach station mode before entering setup.
      let handoffReady = false;
      let lastHandoffStatus = null;

      for (let i = 0; i < 90; i++) {
        const status = await page.evaluate(async (base) => {
          const controller = new AbortController();
          const timer = setTimeout(() => controller.abort(), 4000);

          try {
            const r = await fetch(`${base}/portal/status.json`, {
              cache: "no-store",
              signal: controller.signal
            });
            if (!r.ok) return null;
            return await r.json();
          } catch (_e) {
            return null;
          } finally {
            clearTimeout(timer);
          }
        }, baseUrl);

        if (status) {
          lastHandoffStatus = status;
        }

        if (status && status.last_error) {
          throw new Error(`Portal handoff failed: ${status.last_error}`);
        }

        if (status && status.mode === "station" && status.ip) {
          handoffReady = true;
          break;
        }

        await page.waitForTimeout(2_000);
      }

      if (!handoffReady && requireHandoffReady) {
        throw new Error(`Portal handoff did not reach station mode with local IP. Last status: ${JSON.stringify(lastHandoffStatus)}`);
      } else if (!handoffReady) {
        result.steps.push({ step: "portal_handoff_ready", status: "skip" });
      } else {
        result.steps.push({ step: "portal_handoff_ready", status: "ok" });
      }
    } else if (flowMode !== "setup_only") {
      throw new Error(`Unsupported PI_E2E_FLOW_MODE: ${flowMode}`);
    }

    await page.goto(`${baseUrl}/setup`, { waitUntil: "domcontentloaded", timeout: 60_000 });
    result.steps.push({ step: "goto_setup", status: "ok" });
    await waitForSetupReady(page, result.steps, baseUrl);

    const providerPanel = page.locator("#provider-panel.panel.active, #provider-panel.active");

    if ((await providerPanel.count()) === 0) {
      // Explicitly request preflight check in case AutoRun hook timing is missed.
      await pushLiveEvent(page, "run_preflight", {}, 10_000);

      const preflightContinue = page.locator(".wizard-footer").getByRole("button", { name: "Continue", exact: true });
      const clicked = await clickWhenEnabled(preflightContinue, 180_000);
      if (!clicked) {
        throw new Error("Preflight Continue did not become enabled within 180s.");
      }

      const advanced = await pushLiveEvent(page, "nav_next", {}, 10_000);
      if (!advanced) {
        // Fallback to direct footer click if LiveView channel is still warming.
        await preflightContinue.first().click({ timeout: 15_000, force: true });
      }

      result.steps.push({ step: "preflight_continue", status: "ok" });

      let providerReady = false;
      for (let i = 0; i < 60; i++) {
        if ((await providerPanel.count()) > 0) {
          providerReady = true;
          break;
        }
        await page.waitForTimeout(500);
      }

      if (!providerReady) {
        throw new Error("Did not reach active provider panel after preflight continue.");
      }
    } else {
      result.steps.push({ step: "preflight_continue", status: "skip" });
    }

    const providerCards = page.locator("#provider-panel.panel.active .provider-type-card, #provider-panel.active .provider-type-card");
    if ((await providerCards.count()) > 0) {
      await providerCards.first().click({ timeout: 15_000 });
      result.steps.push({ step: "provider_card_select", status: "ok" });
    } else {
      result.steps.push({ step: "provider_card_select", status: "skip" });
    }

    if (providerMode === "compatible") {
      let compatForm = page.locator("#provider-panel .openai-sub.active form[phx-submit='submit_compatible']").first();
      if ((await compatForm.count()) === 0 || !(await compatForm.isVisible().catch(() => false))) {
        const backToTypeAction = page.locator("#provider-panel button[phx-click='provider_back_to_type']").first();
        if ((await backToTypeAction.count()) > 0 && (await backToTypeAction.isVisible())) {
          await backToTypeAction.click({ timeout: 15_000, force: true });
          result.steps.push({ step: "provider_back_to_type", status: "ok" });
        } else {
          result.steps.push({ step: "provider_back_to_type", status: "skip" });
        }

        const chooseCompatibleAction = page.locator("#provider-panel button[phx-click='choose_compatible']").first();
        if ((await chooseCompatibleAction.count()) > 0 || (await backToTypeAction.count()) > 0) {
          for (let i = 0; i < 20; i++) {
            if ((await chooseCompatibleAction.count()) > 0 && (await chooseCompatibleAction.isVisible().catch(() => false))) {
              break;
            }
            await page.waitForTimeout(500);
          }
        }

        if ((await chooseCompatibleAction.count()) > 0 && (await chooseCompatibleAction.isVisible().catch(() => false))) {
          await chooseCompatibleAction.click({ timeout: 15_000, force: true });
          result.steps.push({ step: "provider_choose_compatible_action", status: "ok" });
        } else {
          const choseCompatible = await pushLiveEvent(page, "choose_compatible", {}, 10_000);
          result.steps.push({
            step: "provider_choose_compatible_action",
            status: choseCompatible ? "ok" : "skip"
          });
        }
      } else {
        result.steps.push({ step: "provider_back_to_type", status: "skip" });
        result.steps.push({ step: "provider_choose_compatible_action", status: "skip" });
      }

      compatForm = page.locator("#provider-panel .openai-sub.active form[phx-submit='submit_compatible']").first();

      if ((await compatForm.count()) === 0 || !(await compatForm.isVisible().catch(() => false))) {
        const compatCard = page
          .locator("#provider-panel .provider-type-card")
          .filter({ hasText: /Other Provider|OpenAI-compatible|LiteLLM|Fireworks|Groq/i })
          .first();

        if ((await compatCard.count()) > 0 && (await compatCard.isVisible())) {
          await compatCard.click({ timeout: 15_000, force: true });
        } else if ((await providerCards.count()) > 1) {
          await providerCards.nth(1).click({ timeout: 15_000, force: true });
        } else {
          throw new Error("Compatible provider card not found.");
        }
      }

      result.steps.push({ step: "provider_select_compatible", status: "ok" });

      compatForm = page.locator("#provider-panel .openai-sub.active form[phx-submit='submit_compatible']").first();
      await compatForm.waitFor({ state: "visible", timeout: 30_000 });

      const baseUrlInput = compatForm.locator("#base-url-input, input[name='base_url']").first();
      const apiKeyInput = compatForm.locator("#compat-api-key-input, input[name='api_key']").first();
      const modelIdInput = compatForm.locator("#model-id-input, input[name='model_id']").first();
      const displayNameInput = compatForm.locator("#display-name-input, input[name='display_name']").first();

      await baseUrlInput.fill(providerBaseUrl, { timeout: 15_000 });
      await apiKeyInput.fill(providerApiKey, { timeout: 15_000 });
      await modelIdInput.fill(providerModelId, { timeout: 15_000 });
      if (providerDisplayName) {
        await displayNameInput.fill(providerDisplayName, { timeout: 15_000 });
      }

      result.steps.push({ step: "provider_compatible_fill", status: "ok" });

      const connectBtn = compatForm.locator("button[type='submit']").first();
      await connectBtn.waitFor({ state: "visible", timeout: 15_000 });
      await connectBtn.click({ timeout: 15_000, force: true });
      result.steps.push({ step: "provider_compatible_save", status: "ok" });
    } else {
      // Prefer direct LiveView event for deterministic transition to API key form.
      let switchedToApi = await pushLiveEvent(page, "openai_use_api_key", {}, 10_000);

      if (!switchedToApi) {
        const useApiKeyBtn = page
          .locator("#provider-panel .openai-sub.active")
          .getByRole("button", { name: /Use API key instead/i });

        if ((await useApiKeyBtn.count()) > 0 && (await useApiKeyBtn.first().isVisible())) {
          await useApiKeyBtn.first().click({ timeout: 15_000, force: true });
          switchedToApi = true;
        }
      }

      let apiField = page.locator(
        "#provider-panel .openai-sub.active input[name='api_key'], #provider-panel .openai-sub.active #api-key-input"
      );

      let apiFieldReady = false;
      for (let i = 0; i < 24; i++) {
        if ((await apiField.count()) > 0 && (await apiField.first().isVisible())) {
          apiFieldReady = true;
          break;
        }
        await page.waitForTimeout(500);
        apiField = page.locator(
          "#provider-panel .openai-sub.active input[name='api_key'], #provider-panel .openai-sub.active #api-key-input"
        );
      }

      result.steps.push({ step: "provider_use_api_key", status: apiFieldReady ? "ok" : "skip" });

      if (!apiFieldReady) {
        throw new Error("API key input not found in active provider panel.");
      }

      await apiField.first().fill(providerApiKey, { timeout: 15_000 });
      result.steps.push({ step: "provider_api_key_fill", status: "ok" });

      const saveApiBtn = page.locator("#provider-panel .openai-sub.active form button[type='submit']").first();
      if ((await saveApiBtn.count()) === 0 || !(await saveApiBtn.isVisible())) {
        throw new Error("Provider save/connect button not found.");
      }

      await saveApiBtn.click({ timeout: 15_000, force: true });
      result.steps.push({ step: "provider_api_key_save", status: "ok" });
    }

    const providerConnectedHeading = page.getByRole("heading", { name: /Provider Connected/i }).first();
    await providerConnectedHeading.waitFor({ state: "visible", timeout: 45_000 });
    result.steps.push({ step: "provider_connected_assert", status: "ok" });

    await clickIfVisible(
      page.locator(".wizard-footer").getByRole("button", { name: "Continue", exact: true }),
      "provider_continue",
      result.steps
    );

    if (telegramMode === "validate_token" || telegramMode === "assist_link") {
      if (!telegramBotToken) {
        throw new Error(`PI_E2E_TELEGRAM_MODE=${telegramMode} requires TEST_TELEGRAM_BOT_TOKEN.`);
      }

      let tgStarted = await pushLiveEvent(page, "tg_start", {}, 10_000);

      if (!tgStarted) {
        const tgStartBtn = page.locator("article.panel.active").getByRole("button", { name: /Set up Telegram/i }).first();
        if ((await tgStartBtn.count()) > 0 && (await tgStartBtn.isVisible())) {
          await tgStartBtn.click({ timeout: 15_000, force: true });
          tgStarted = true;
        }
      }

      const tgTokenInput = page.locator("#tg-token-input").first();
      await tgTokenInput.waitFor({ state: "visible", timeout: 60_000 });
      await tgTokenInput.fill(telegramBotToken, { timeout: 15_000 });

      const connectBotBtn = page.locator("article.panel.active button[type='submit']").filter({ hasText: /Connect bot/i }).first();
      await connectBotBtn.click({ timeout: 15_000, force: true });

      await page.waitForFunction(
        () => {
          const txt = document.body.innerText || "";
          return txt.includes("Say hello to your bot") || txt.includes("Check now");
        },
        { timeout: 30_000 }
      );

      result.steps.push({ step: "telegram_token_validate", status: "ok" });

      if (telegramMode === "assist_link") {
        await waitForTelegramOwnerLink(page, telegramAssistTimeoutSecs, result);

        const continueBtn = page.locator(".wizard-footer").getByRole("button", { name: "Continue", exact: true }).first();
        const continued = await clickWhenEnabled(continueBtn, 30_000);
        if (!continued) {
          throw new Error("Telegram step did not advance after owner link.");
        }

        result.steps.push({ step: "telegram_continue", status: "ok" });
      }
    } else {
      result.steps.push({ step: "telegram_token_validate", status: "skip" });
    }

    if (telegramMode !== "assist_link") {
      let telegramSkipped = false;
      const footerSkip = page.locator(".wizard-footer").getByRole("button", { name: /Skip/i }).first();

      for (let i = 0; i < 40; i++) {
        if ((await footerSkip.count()) > 0 && (await footerSkip.isVisible()) && (await footerSkip.isEnabled())) {
          await footerSkip.click({ timeout: 15_000, force: true });
          telegramSkipped = true;
          break;
        }
        await page.waitForTimeout(500);
      }

      result.steps.push({ step: "telegram_skip", status: telegramSkipped ? "ok" : "skip" });
    } else {
      result.steps.push({ step: "telegram_skip", status: "skip", detail: "assist_link" });
    }

    const dashPwd = page.locator("article.panel.active #dashboard-password");
    for (let i = 0; i < 60; i++) {
      if ((await dashPwd.count()) > 0 && (await dashPwd.first().isVisible())) {
        break;
      }
      await page.waitForTimeout(500);
    }

    if ((await dashPwd.count()) === 0 || !(await dashPwd.first().isVisible())) {
      throw new Error("Dashboard password step not reached.");
    }

    await dashPwd.first().fill(dashboardPassword, { timeout: 15_000 });
    await page.locator("article.panel.active #dashboard-password-confirm").first().fill(dashboardPassword, { timeout: 15_000 });
    result.steps.push({ step: "dashboard_password_fill", status: "ok" });

    const saveDashBtn = page.locator("article.panel.active button[type='submit']").filter({ hasText: /Save and continue/i }).first();
    if ((await saveDashBtn.count()) === 0 || !(await saveDashBtn.isVisible())) {
      throw new Error("Save and continue button missing on dashboard password step.");
    }

    await saveDashBtn.click({ timeout: 15_000, force: true });
    result.steps.push({ step: "dashboard_password_save", status: "ok" });

    const finishCheckbox = page.getByRole("checkbox");
    if ((await finishCheckbox.count()) > 0) {
      await finishCheckbox.first().check({ timeout: 10_000 });
      result.steps.push({ step: "finish_checkbox", status: "ok" });
    } else {
      result.steps.push({ step: "finish_checkbox", status: "skip" });
    }

    const finishBtn = page.getByRole("button", { name: /Finish setup/i });
    if ((await finishBtn.count()) === 0) {
      throw new Error("Finish setup button not found.");
    }

    await finishBtn.first().click({ timeout: 15_000 });
    result.steps.push({ step: "finish_setup", status: "ok" });

    // Setup completion can take time while services restart/apply config.
    await page.waitForFunction(
      () => window.location.pathname !== "/setup",
      { timeout: 120_000 }
    ).catch(() => {});

    result.finalUrl = page.url();

    if (/\/setup(?:$|\?)/.test(result.finalUrl)) {
      throw new Error(`Setup did not redirect away from /setup within timeout; current URL: ${result.finalUrl}`);
    }

    if (!(/\/$/.test(result.finalUrl) || /\/login$/.test(result.finalUrl))) {
      throw new Error(`Expected redirect to / or /login, got: ${result.finalUrl}`);
    }

    result.steps.push({ step: "assert_post_setup_redirect", status: "ok" });

    if (telegramMode === "assist_link") {
      await loginToDashboard(page, baseUrl, dashboardPassword, result.steps);
      await page.goto(`${baseUrl}/telegram`, { waitUntil: "domcontentloaded", timeout: 30_000 });
      await page.getByRole("heading", { name: /^Telegram$/i }).first().waitFor({ state: "visible", timeout: 30_000 });
      await page.getByText(/^Connected$/i).first().waitFor({ state: "visible", timeout: 30_000 });
      await page.getByText(/Owner linked/i).first().waitFor({ state: "visible", timeout: 30_000 });
      result.steps.push({ step: "dashboard_telegram_connected_assert", status: "ok" });

      if (telegramSendTest) {
        const sendTestBtn = page.getByRole("button", { name: /Send test notification/i }).first();
        await sendTestBtn.waitFor({ state: "visible", timeout: 30_000 });
        await sendTestBtn.click({ timeout: 15_000, force: true });
        await page.getByText(/Test notification sent\./i).first().waitFor({ state: "visible", timeout: 30_000 });
        result.steps.push({ step: "dashboard_telegram_test_notification", status: "ok" });
      } else {
        result.steps.push({ step: "dashboard_telegram_test_notification", status: "skip" });
      }
    }

    if (tailscaleMode === "connect") {
      if (!tailscaleAuthKey) {
        throw new Error("PI_E2E_TAILSCALE_MODE=connect requires TEST_TAILSCALE_AUTH_KEY.");
      }

      if (!/\/login$/.test(page.url())) {
        await page.goto(`${baseUrl}/login`, { waitUntil: "domcontentloaded", timeout: 30_000 });
      }

      const loginPassword = page.locator("#login-password").first();
      await loginPassword.waitFor({ state: "visible", timeout: 30_000 });
      await loginPassword.fill(dashboardPassword, { timeout: 15_000 });
      await page.getByRole("button", { name: /Sign in/i }).first().click({ timeout: 15_000 });
      result.steps.push({ step: "tailscale_login", status: "ok" });
      const systemTab = page.getByRole("link", { name: /^System$/i }).first();
      await systemTab.waitFor({ state: "visible", timeout: 30_000 });
      await systemTab.click({ timeout: 15_000 });
      result.steps.push({ step: "tailscale_open_system_tab", status: "ok" });

      const disconnectBtn = page.getByRole("button", { name: /Disconnect/i }).first();
      if ((await disconnectBtn.count()) > 0 && (await disconnectBtn.isVisible())) {
        await disconnectBtn.click({ timeout: 15_000, force: true });
        result.steps.push({ step: "tailscale_disconnect_existing", status: "ok" });
        await page.waitForTimeout(2_000);
      } else {
        result.steps.push({ step: "tailscale_disconnect_existing", status: "skip" });
      }

      const tailscaleForm = page.locator("form[phx-submit='tailscale_connect']").first();
      await tailscaleForm.waitFor({ state: "visible", timeout: 45_000 });

      const keyInput = tailscaleForm.locator("#tailscale-key-input").first();
      await keyInput.waitFor({ state: "visible", timeout: 45_000 });
      await keyInput.fill(tailscaleAuthKey, { timeout: 15_000 });

      const connectBtn = tailscaleForm.locator("button[type='submit']").first();
      await connectBtn.waitFor({ state: "visible", timeout: 45_000 });
      await connectBtn.click({ timeout: 20_000, force: true });
      result.steps.push({ step: "tailscale_connect_submit", status: "ok" });

      const connectedBadge = page.locator(".tailscale-status .wifi-status-badge.online").first();
      await connectedBadge.waitFor({ state: "visible", timeout: 90_000 });
      result.steps.push({ step: "tailscale_connected_assert", status: "ok" });
    } else {
      result.steps.push({ step: "tailscale_flow", status: "skip" });
    }
  } catch (error) {
    result.ok = false;
    result.error = String(error?.message || error);
    result.finalUrl = page.url();
  } finally {
    await page.screenshot({ path: "./.tmp/pi-happy-path-final.png", fullPage: true }).catch(() => {});
    await browser.close();
  }

  console.log(JSON.stringify(result));
  if (!result.ok) {
    process.exit(2);
  }
}

run();
