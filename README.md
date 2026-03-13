# ClawRig

[![Build Pi Image](https://github.com/recursive-systems/clawrig/actions/workflows/build-image.yml/badge.svg)](https://github.com/recursive-systems/clawrig/actions/workflows/build-image.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Device management UI for [OpenClaw](https://openclaw.com) on Raspberry Pi.

ClawRig turns a Raspberry Pi into a dedicated OpenClaw appliance — providing an out-of-box setup wizard, dashboard, captive portal for Wi-Fi configuration, OTA updates, and Gateway node integration. It connects to the local OpenClaw Gateway as a node, advertising device capabilities (network, hardware, diagnostics) that agents can invoke remotely.

Learn more at [clawrig.co](https://clawrig.co).

## Quick start

### Flash a Pi from a GitHub Release

Download the latest image:

```bash
gh release download --repo recursive-systems/clawrig --pattern '*.img.zip'
```

Or download directly from the [releases page](https://github.com/recursive-systems/clawrig/releases).

Flash it:

1. Install [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Choose OS > **Use custom** > select the downloaded `.img.zip`
3. Select your SD card
4. In settings, optionally configure Wi-Fi so the Pi joins your network on first boot
5. Click **Write**

### After boot

- Hostname: `clawrig` (reachable at `clawrig.local` via mDNS)
- SSH: `ssh pi@clawrig.local` (default password: `clawrig`)
- Web UI: http://clawrig.local
- If no Wi-Fi is configured, the Pi broadcasts a `ClawRig-Setup` hotspot with a captive portal

## Prerequisites

- **Raspberry Pi 4 or 5** (ARM64)
- **OpenClaw Gateway** — installed automatically during setup (`openclaw onboard --install-daemon`)

## Development

```bash
mix setup
mix phx.server
```

Visit http://localhost:4090. On macOS/Linux dev machines, ClawRig uses mock system commands so you don't need a Pi.

Run tests and checks:

```bash
mix test
mix precommit   # compile (warnings-as-errors) + format + test
```

Browser-based UX checks (no Pi required):

```bash
npm install
npm run e2e:install
npm run e2e
```

The Playwright harness starts ClawRig on a separate local port with mock system
commands, preview states, dev auth bypass, and isolated temp state files so you
can exercise portal, setup, and dashboard flows end-to-end.

## Fleet Telemetry

ClawRig includes a generic fleet heartbeat sender (disabled by default) so
open-source ClawRig can target any backend with a compatible payload.

Enable sender in production via environment:

- `CLAWRIG_FLEET_ENABLED=true`
- `CLAWRIG_FLEET_ENDPOINT=https://<fleet-backend>/api/v1/heartbeats`
- `CLAWRIG_FLEET_DEVICE_TOKEN=<device-token>`
- `CLAWRIG_FLEET_ORG_SLUG=<org-slug>`
- `CLAWRIG_FLEET_SITE_CODE=<site-code>`

Optional:

- `CLAWRIG_FLEET_INTERVAL_MS=60000`
- `CLAWRIG_FLEET_REQUIRE_OOBE=true`
- `CLAWRIG_FLEET_ORG_NAME`, `CLAWRIG_FLEET_SITE_NAME`

## Configuration

| Environment variable | Description | Default |
|---|---|---|
| `SECRET_KEY_BASE` | Phoenix session secret (required in prod) | — |
| `PHX_HOST` | Hostname for URL generation | `<hostname>.local` |
| `PORT` | HTTP listen port | `4090` |
| `GITHUB_TOKEN` | Optional; higher rate limits for OTA update checks | — |

Application config (in `config/`):

| Key | Description | Default |
|---|---|---|
| `:search_proxy_url` | Search proxy service URL | `https://rs-search-proxy.fly.dev` |
| `:browser_use_broker_url` | Browser Use broker service URL | `https://rs-browser-use.fly.dev` |
| `:openai_client_id` | OpenAI OAuth client ID for device code flow | built-in |
| `:auth_profiles_path` | Path to OpenClaw auth profiles JSON | `~/.openclaw/agents/main/agent/auth-profiles.json` |

## Building a Pi image

Requires Docker.

```bash
# Build a flashable golden image (ARM64, ~7 min on Apple Silicon)
bash deploy/build-image.sh

# Or just the release tarball for manual deployment
bash deploy/build-release.sh
scp -r deploy/bundle/* pi@<pi-ip>:~/clawrig-deploy/
ssh pi@<pi-ip> 'cd ~/clawrig-deploy && bash pi-setup.sh'
```

## Cutting a release

Tag and push to trigger the CI build:

```bash
git tag v0.2.0
git push origin v0.2.0
```

GitHub Actions builds the golden image and attaches it to the release.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Copyright 2026 Recursive Systems LLC. Licensed under [Apache License 2.0](LICENSE).
