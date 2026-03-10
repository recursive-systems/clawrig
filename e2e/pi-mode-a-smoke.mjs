import { chromium } from "@playwright/test";

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
}

async function gotoAndCapture(page, url, waitUntil = "domcontentloaded") {
  const response = await page.goto(url, { waitUntil, timeout: 60_000 });
  return {
    url: page.url(),
    status: response?.status() ?? null
  };
}

async function classifyUiState(page, baseUrl, dashboardPassword, steps) {
  await page.goto(`${baseUrl}/`, { waitUntil: "domcontentloaded", timeout: 60_000 });

  if (/\/portal(?:$|\?)/.test(page.url())) {
    await page.getByRole("heading", { name: /Wi-Fi Setup/i }).first().waitFor({ state: "visible", timeout: 30_000 });
    steps.push({ step: "ui_state", status: "ok", detail: "portal" });
    return "portal";
  }

  if (/\/setup(?:$|\?)/.test(page.url())) {
    await page.getByText("ClawRig").first().waitFor({ state: "visible", timeout: 30_000 });
    steps.push({ step: "ui_state", status: "ok", detail: "setup" });
    return "setup";
  }

  if (/\/login(?:$|\?)/.test(page.url())) {
    if (!dashboardPassword) {
      steps.push({ step: "dashboard_login", status: "skip", detail: "missing_TEST_DASHBOARD_PASSWORD" });
      steps.push({ step: "ui_state", status: "ok", detail: "login_locked" });
      return "login_locked";
    }

    const passwordInput = page.locator("#login-password").first();
    await passwordInput.waitFor({ state: "visible", timeout: 30_000 });
    await passwordInput.fill(dashboardPassword, { timeout: 15_000 });
    await page.getByRole("button", { name: /Sign in/i }).first().click({ timeout: 15_000 });
    steps.push({ step: "dashboard_login", status: "ok" });
  } else {
    steps.push({ step: "dashboard_login", status: "skip" });
  }

  const overview = page.getByText("Overview").first();
  await overview.waitFor({ state: "visible", timeout: 30_000 });
  steps.push({ step: "ui_state", status: "ok", detail: "dashboard" });
  return "dashboard";
}

async function run() {
  const host = requireEnv("TEST_PI_HOST");
  const dashboardPassword = process.env.TEST_DASHBOARD_PASSWORD || "";
  const baseUrl = `http://${host}`;

  const result = {
    ok: true,
    baseUrl,
    finalUrl: "",
    steps: []
  };

  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  try {
    const root = await gotoAndCapture(page, `${baseUrl}/`);
    result.steps.push({ step: "probe_root", status: root.status && root.status < 500 ? "ok" : "fail", detail: `status=${root.status}` });

    const portal = await gotoAndCapture(page, `${baseUrl}/portal`);
    if (portal.status !== 200) {
      throw new Error(`Expected /portal status 200, got ${portal.status}`);
    }
    result.steps.push({ step: "probe_portal", status: "ok", detail: `status=${portal.status}` });

    const setup = await gotoAndCapture(page, `${baseUrl}/setup`);
    if (setup.status && setup.status >= 500) {
      throw new Error(`Unexpected /setup server error: ${setup.status}`);
    }
    result.steps.push({ step: "probe_setup", status: "ok", detail: `status=${setup.status}` });

    const uiState = await classifyUiState(page, baseUrl, dashboardPassword, result.steps);

    if (uiState === "dashboard") {
      await page.getByText("Dashboard Address").first().waitFor({ state: "visible", timeout: 30_000 });
      await page.getByText("Next Step").first().waitFor({ state: "visible", timeout: 30_000 });
      await page.getByText("AI Provider").first().waitFor({ state: "visible", timeout: 30_000 });
      result.steps.push({ step: "dashboard_overview_assert", status: "ok" });

      await page.goto(`${baseUrl}/system`, { waitUntil: "domcontentloaded", timeout: 30_000 });
      await page.getByRole("heading", { name: /^System$/i }).first().waitFor({ state: "visible", timeout: 30_000 });
      await page.getByRole("button", { name: /Check for Updates/i }).first().waitFor({ state: "visible", timeout: 30_000 });
      result.steps.push({ step: "system_page_assert", status: "ok" });

      await page.goto(`${baseUrl}/account`, { waitUntil: "domcontentloaded", timeout: 30_000 });
      await page.getByRole("heading", { name: /AI Provider/i }).first().waitFor({ state: "visible", timeout: 30_000 });
      result.steps.push({ step: "account_page_assert", status: "ok" });

      await page.goto(`${baseUrl}/telegram`, { waitUntil: "domcontentloaded", timeout: 30_000 });
      await page.getByRole("heading", { name: /Telegram/i }).first().waitFor({ state: "visible", timeout: 30_000 });
      result.steps.push({ step: "telegram_page_assert", status: "ok" });
    } else {
      result.steps.push({ step: "dashboard_overview_assert", status: "skip", detail: `ui_state=${uiState}` });
      result.steps.push({ step: "system_page_assert", status: "skip", detail: `ui_state=${uiState}` });
      result.steps.push({ step: "account_page_assert", status: "skip", detail: `ui_state=${uiState}` });
      result.steps.push({ step: "telegram_page_assert", status: "skip", detail: `ui_state=${uiState}` });
    }

    result.finalUrl = page.url();
  } catch (error) {
    result.ok = false;
    result.error = String(error?.message || error);
    result.finalUrl = page.url();
  } finally {
    await page.screenshot({ path: "./.tmp/pi-mode-a-final.png", fullPage: true }).catch(() => {});
    await browser.close();
  }

  console.log(JSON.stringify(result));
  if (!result.ok) {
    process.exit(2);
  }
}

run();
