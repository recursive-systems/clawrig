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

## Configuration

| Environment variable | Description | Default |
|---|---|---|
| `SECRET_KEY_BASE` | Phoenix session secret (required in prod) | — |
| `PHX_HOST` | Hostname for URL generation | `<hostname>.local` |
| `PORT` | HTTP listen port | `4090` |
| `SEARCH_PROXY_SECRET` | Registration secret for search proxy | — |
| `GITHUB_TOKEN` | Optional; higher rate limits for OTA update checks | — |

Application config (in `config/`):

| Key | Description | Default |
|---|---|---|
| `:search_proxy_url` | Search proxy service URL | `https://rs-search-proxy.fly.dev` |
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
