import { expect, test } from "@playwright/test";

import { resetApp } from "./helpers/app";

test.describe("captive portal", () => {
  test.beforeEach(async ({ request }) => {
    await resetApp(request);
  });

  test("shows mock networks and Wi-Fi handoff guidance", async ({ page }) => {
    await page.goto("/portal");

    await expect(page.getByRole("heading", { name: "Wi-Fi Setup" })).toBeVisible();
    await expect(page.getByText("MyHomeWiFi")).toBeVisible();

    await page.getByRole("radio", { name: /MyHomeWiFi/ }).check();
    await page.getByLabel("Password").fill("example-password");
    await page.getByRole("button", { name: "Connect" }).click();

    await expect(page.getByRole("heading", { name: "Wi-Fi credentials saved" })).toBeVisible();
    await expect(page.getByText("Copy this address")).toBeVisible();
    await expect(page.locator("#address-value")).toContainText(".local");
    await expect(page.getByText("Open this address on your computer to continue setup.")).toBeVisible();
  });
});
