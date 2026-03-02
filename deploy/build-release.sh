#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "==> Building ARM64 release via Docker..."
# Use buildx if available (for cross-compilation on x86), otherwise plain docker build.
# On Apple Silicon, plain docker build already produces arm64 images.
if docker buildx version &>/dev/null; then
  docker buildx build \
    --platform linux/arm64 \
    -f "$SCRIPT_DIR/Dockerfile.build" \
    -t clawrig-build \
    --load \
    "$PROJECT_DIR"
else
  docker build \
    -f "$SCRIPT_DIR/Dockerfile.build" \
    -t clawrig-build \
    "$PROJECT_DIR"
fi

echo "==> Extracting tarball..."
docker create --name clawrig-extract clawrig-build true 2>/dev/null || \
  (docker rm clawrig-extract && docker create --name clawrig-extract clawrig-build true)
docker cp clawrig-extract:/app/clawrig.tar.gz "$SCRIPT_DIR/clawrig.tar.gz"
docker rm clawrig-extract

echo "==> Assembling deploy bundle..."
BUNDLE_DIR="$SCRIPT_DIR/bundle"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"
cp "$SCRIPT_DIR/clawrig.tar.gz" "$BUNDLE_DIR/"
cp "$SCRIPT_DIR/pi-setup.sh" "$BUNDLE_DIR/"
cp "$SCRIPT_DIR/dnsmasq-captive.conf" "$BUNDLE_DIR/"
cp "$SCRIPT_DIR/clawrig-avahi.service" "$BUNDLE_DIR/"
cp "$SCRIPT_DIR/systemd/clawrig.service" "$BUNDLE_DIR/"

# Watchdog and self-healing files
WATCHDOG_DIR="$SCRIPT_DIR/pi-gen/stage-clawrig/04-configure-watchdog/files"
cp "$WATCHDOG_DIR/clawrig-gateway-watchdog.sh" "$BUNDLE_DIR/"
cp "$WATCHDOG_DIR/clawrig-gateway-watchdog.service" "$BUNDLE_DIR/"
cp "$WATCHDOG_DIR/clawrig-gateway-watchdog.timer" "$BUNDLE_DIR/"
cp "$WATCHDOG_DIR/clawrig-daily-repair.sh" "$BUNDLE_DIR/"
cp "$WATCHDOG_DIR/clawrig-daily-repair.service" "$BUNDLE_DIR/"
cp "$WATCHDOG_DIR/clawrig-daily-repair.timer" "$BUNDLE_DIR/"

echo ""
echo "Done! Deploy bundle: $BUNDLE_DIR/"
echo ""
echo "To deploy to Pi:"
echo "  scp -r $BUNDLE_DIR/* pi@<pi-ip>:~/clawrig-deploy/"
echo "  ssh pi@<pi-ip> 'cd ~/clawrig-deploy && bash pi-setup.sh'"
