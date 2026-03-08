import { expect, test } from "@playwright/test";

import { resetApp } from "./helpers/app";

test.describe("dashboard previews", () => {
  test("surfaces provider reconnect guidance first", async ({ page, request }) => {
    await resetApp(request, { oobeComplete: true });

    await page.goto("/?preview=provider-disconnected");

    await expect(page.getByText("Overview")).toBeVisible();
    await expect(page.getByRole("heading", { name: "Finish connecting your AI provider" })).toBeVisible();
    await expect(page.getByText("Your dashboard is up, but OpenClaw will not be fully usable until your provider is connected.")).toBeVisible();
    await expect(page.getByText("Dashboard Address")).toBeVisible();
    await expect(page.getByText("Next Step")).toBeVisible();
    await expect(page.getByRole("link", { name: "Open Provider" })).toBeVisible();
  });

  test("surfaces recovery-oriented system guidance for risky update states", async ({
    page,
    request,
  }) => {
    await resetApp(request, { oobeComplete: true });

    await page.goto("/system?preview=update-pending-recovery");

    await expect(page.getByText("A new update (v5.4.0) is ready.")).toBeVisible();
    await expect(page.getByRole("button", { name: "Check for Updates" })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Auto-healing" })).toBeVisible();
  });
});
