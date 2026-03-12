import { expect, test } from "@playwright/test";

import { resetApp, startSetup } from "./helpers/app";

test.describe("setup wizard", () => {
  test.beforeEach(async ({ request }) => {
    await resetApp(request);
  });

  test("persists the device-code step across a resumed setup session", async ({ page }) => {
    await startSetup(page);

    await page.locator("#provider-panel .provider-type-card").first().click();
    await page.locator("#provider-panel").getByRole("button", { name: "Sign in with ChatGPT" }).click();

    await expect(page.getByText("Before you start:")).toBeVisible();
    await expect(page.getByText("Device code authorization for Codex")).toBeVisible();
    await expect(page.locator("#device-code-text")).toBeVisible();

    await page.goto("/setup");

    await expect(page.getByRole("heading", { name: "Completing sign-in…" })).toBeVisible();
    await expect(page.getByText("Checking your authorization with OpenAI.")).toBeVisible();
    await expect(page.getByRole("button", { name: "Start over" })).toBeVisible();
  });

  test("can complete setup with the dev auth bypass and lands on dashboard login", async ({
    page,
  }) => {
    await startSetup(page);

    await page.locator("#provider-panel .provider-type-card").first().click();
    await page.locator("#provider-panel").getByRole("button", { name: "Use API key instead" }).click();
    await page.getByLabel("API key").fill("sk_test_local_preview");
    await page.getByRole("button", { name: "Save API key" }).click();

    await expect(page.getByRole("heading", { name: "Provider Connected" })).toBeVisible();
    await page.locator(".wizard-footer").getByRole("button", { name: "Continue", exact: true }).click();

    await expect(page.getByRole("heading", { name: "Telegram" })).toBeVisible();
    await expect(page.getByText("This step is optional.")).toBeVisible();
    await page.getByRole("button", { name: "Skip" }).click();

    await expect(page.getByRole("heading", { name: "Secure your dashboard" })).toBeVisible();
    await page.locator("#dashboard-password").fill("ClawRig123!");
    await page.locator("#dashboard-password-confirm").fill("ClawRig123!");
    await page.getByRole("button", { name: "Save and continue" }).click();

    await expect(page.getByRole("heading", { name: "You're all set" })).toBeVisible();
    await expect(page.getByText("Use your IP address")).toBeVisible();
    await expect(page.getByText("Try your .local address")).toBeVisible();
    await expect(page.getByText("If you lose the link later")).toBeVisible();

    await page.getByRole("checkbox").check();
    await page.getByRole("button", { name: "Finish setup" }).click();

    await expect(page).toHaveURL(/\/login$/);
    await expect(page.getByRole("heading", { name: "Dashboard Login" })).toBeVisible();
  });
});
