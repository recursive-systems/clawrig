#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Use docker if available, fall back to podman
if command -v docker &>/dev/null && docker info &>/dev/null; then
  DOCKER=docker
elif command -v podman &>/dev/null; then
  DOCKER=podman
else
  echo "Error: docker or podman required" >&2
  exit 1
fi

VERSION_ARG=""
if [ -n "${CLAWRIG_VERSION:-}" ]; then
  VERSION_ARG="--build-arg CLAWRIG_VERSION=$CLAWRIG_VERSION"
fi

echo "==> Building ARM64 release via $DOCKER..."
# Use buildx if available (for cross-compilation on x86), otherwise plain build.
# On Apple Silicon, plain build already produces arm64 images.
if [ "$DOCKER" = "docker" ] && docker buildx version &>/dev/null; then
  docker buildx build \
    --platform linux/arm64 \
    -f "$SCRIPT_DIR/Dockerfile.build" \
    -t clawrig-build \
    --load \
    $VERSION_ARG \
    "$PROJECT_DIR"
else
  $DOCKER build \
    -f "$SCRIPT_DIR/Dockerfile.build" \
    -t clawrig-build \
    $VERSION_ARG \
    "$PROJECT_DIR"
fi

echo "==> Extracting tarball..."
$DOCKER create --name clawrig-extract clawrig-build true 2>/dev/null || \
  ($DOCKER rm clawrig-extract && $DOCKER create --name clawrig-extract clawrig-build true)
$DOCKER cp clawrig-extract:/app/clawrig.tar.gz "$SCRIPT_DIR/clawrig.tar.gz"
$DOCKER rm clawrig-extract

echo "==> Assembling deploy bundle..."
BUNDLE_DIR="$SCRIPT_DIR/bundle"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"
cp "$SCRIPT_DIR/clawrig.tar.gz" "$BUNDLE_DIR/"
cp "$SCRIPT_DIR/pi-setup.sh" "$BUNDLE_DIR/"
cp "$SCRIPT_DIR/dnsmasq-captive.conf" "$BUNDLE_DIR/"
cp "$SCRIPT_DIR/clawrig-avahi.service" "$BUNDLE_DIR/"
cp "$SCRIPT_DIR/systemd/clawrig.service" "$BUNDLE_DIR/"

# OTA update infrastructure
INSTALL_DIR="$SCRIPT_DIR/pi-gen/stage-clawrig/01-install-clawrig/files"
cp "$INSTALL_DIR/clawrig-updater-sudoers" "$BUNDLE_DIR/"
if [ -f "$INSTALL_DIR/update-pubkey.pem" ]; then
  cp "$INSTALL_DIR/update-pubkey.pem" "$BUNDLE_DIR/"
fi

# ClawRig OpenClaw plugin — check multiple locations:
#   1. CLAWRIG_PLUGIN_DIR env var (set by CI after cloning the plugin repo)
#   2. Monorepo sibling path (local dev from openclaw_monorepo)
PLUGIN_SRC="${CLAWRIG_PLUGIN_DIR:-}"
if [ -z "$PLUGIN_SRC" ]; then
  # Local dev: plugin lives at plugins/clawrig/ relative to monorepo root
  MONOREPO_PLUGIN="$PROJECT_DIR/../../../plugins/clawrig"
  if [ -d "$MONOREPO_PLUGIN" ]; then
    PLUGIN_SRC="$MONOREPO_PLUGIN"
  fi
fi
if [ -n "$PLUGIN_SRC" ] && [ -d "$PLUGIN_SRC" ]; then
  mkdir -p "$BUNDLE_DIR/clawrig-plugin/scripts"
  cp -a "$PLUGIN_SRC/skills" "$BUNDLE_DIR/clawrig-plugin/skills"
  cp "$PLUGIN_SRC/scripts/clawrig-info" "$BUNDLE_DIR/clawrig-plugin/scripts/"
  echo "  Bundled ClawRig plugin from $PLUGIN_SRC"
else
  echo "  Warning: ClawRig plugin not found, skipping"
fi

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
