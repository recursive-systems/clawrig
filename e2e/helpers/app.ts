import { expect, type APIRequestContext, type Page } from "@playwright/test";

export async function resetApp(
  request: APIRequestContext,
  opts: { oobeComplete?: boolean } = {},
): Promise<void> {
  const response = await request.post("/__e2e__/reset", {
    data: { oobe_complete: opts.oobeComplete ?? false },
  });

  expect(response.ok()).toBeTruthy();
}

export async function startSetup(page: Page): Promise<void> {
  await page.goto("/setup");
  await expect(page.locator("#preflight-panel h2")).toHaveText("You're online");
  await page.locator(".wizard-footer").getByRole("button", { name: "Continue", exact: true }).click();
  await expect(page.locator("#provider-panel h2")).toHaveText("AI Provider");
}
