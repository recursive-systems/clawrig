# ClawRig

Device management UI for OpenClaw on Raspberry Pi 4.

## Flashing a Pi

### From a GitHub Release (easiest)

Download the latest image from any computer with `gh` installed:

```bash
gh release download --repo recursive-systems/clawrig --pattern '*.img.zip'
```

Or download directly from https://github.com/recursive-systems/clawrig/releases

Then flash it:

1. Install [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Choose OS > **Use custom** > select the downloaded `.img.zip`
3. Select your SD card (micro SD with adapter works fine)
4. In settings (gear icon), optionally configure Wi-Fi so the Pi joins your network on first boot
5. Click **Write**

### After boot

- Hostname: `clawrig` (reachable at `clawrig.local` via mDNS)
- SSH: `ssh pi@clawrig.local` (default password: `clawrig`)
- ClawRig UI: http://clawrig.local:4090
- If no Wi-Fi is configured, the Pi broadcasts a `ClawRig-Setup` hotspot with a captive portal

## Building locally

Requires Docker.

```bash
# Build a flashable golden image (ARM64, ~7 min on Apple Silicon)
bash deploy/build-image.sh

# Output: deploy/pi-gen/pi-gen-repo/deploy/image_*.zip
```

Or build just the release tarball for manual deployment:

```bash
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

GitHub Actions builds the golden image and attaches it to the release automatically.

## Development

```bash
mix setup
mix phx.server
```

Visit http://localhost:4090

## Default credentials

| Field | Value |
|-------|-------|
| Pi user | `pi` |
| Pi password | `clawrig` |
| Web UI port | `4090` |
| SSH | enabled |
