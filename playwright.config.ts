import { defineConfig, devices } from "@playwright/test";

const port = 4101;
const tmpDir = ".tmp/e2e";

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: 1,
  reporter: [["list"], ["html", { open: "never" }]],
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    trace: "on-first-retry",
    screenshot: "only-on-failure",
    video: "retain-on-failure"
  },
  projects: [
    {
      name: "desktop-chromium",
      use: { ...devices["Desktop Chrome"] }
    },
    {
      name: "mobile-chromium",
      use: { ...devices["Pixel 7"] }
    }
  ],
  webServer: {
    command: [
      "PORT=4101",
      "PHX_HOST=127.0.0.1",
      "CLAWRIG_SYSTEM_COMMANDS=mock",
      "CLAWRIG_ENABLE_PREVIEW_STATES=true",
      "CLAWRIG_ENABLE_DEV_AUTH_BYPASS=true",
      "CLAWRIG_ENABLE_E2E_ROUTES=true",
      `CLAWRIG_STATE_PATH=${tmpDir}/wizard-state.json`,
      `CLAWRIG_OOBE_MARKER=${tmpDir}/.oobe-complete`,
      `CLAWRIG_NODE_IDENTITY_PATH=${tmpDir}/node-identity.json`,
      `CLAWRIG_DASHBOARD_AUTH_PATH=${tmpDir}/dashboard-auth.json`,
      "mise exec -- mix phx.server"
    ].join(" "),
    url: `http://127.0.0.1:${port}`,
    reuseExistingServer: false,
    timeout: 120_000
  }
});
