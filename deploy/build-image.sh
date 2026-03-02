#!/usr/bin/env bash
set -e

# Build a flashable Raspberry Pi OS image with ClawRig OOBE baked in.
#
# Prerequisites: Docker
#
# Usage:
#   cd clawrig
#   bash deploy/build-image.sh
#
# Output: deploy/pi-gen/pi-gen-repo/deploy/clawrig-*.img.zip

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIGEN_DIR="$SCRIPT_DIR/pi-gen"

echo "============================================"
echo "  ClawRig - Build Raspberry Pi Image"
echo "============================================"

# -----------------------------------------------
# Step 1: Build the ARM64 Elixir release
# -----------------------------------------------
echo ""
echo "==> Step 1: Building ARM64 Elixir release..."
bash "$SCRIPT_DIR/build-release.sh"

# -----------------------------------------------
# Step 2: Stage files for pi-gen
# -----------------------------------------------
echo ""
echo "==> Step 2: Staging files for pi-gen..."

# Copy release tarball into the custom stage
cp "$SCRIPT_DIR/bundle/clawrig.tar.gz" \
   "$PIGEN_DIR/stage-clawrig/01-install-clawrig/files/clawrig.tar.gz"

cp "$SCRIPT_DIR/bundle/clawrig.service" \
   "$PIGEN_DIR/stage-clawrig/01-install-clawrig/files/clawrig.service"

# Copy networking config files
cp "$SCRIPT_DIR/bundle/dnsmasq-captive.conf" \
   "$PIGEN_DIR/stage-clawrig/02-configure-networking/files/dnsmasq-captive.conf"

cp "$SCRIPT_DIR/bundle/clawrig-avahi.service" \
   "$PIGEN_DIR/stage-clawrig/02-configure-networking/files/clawrig-avahi.service"

# -----------------------------------------------
# Step 3: Clone pi-gen arm64 branch (if needed)
# -----------------------------------------------
echo ""
echo "==> Step 3: Setting up pi-gen (arm64 branch)..."

PIGEN_REPO="$PIGEN_DIR/pi-gen-repo"
if [ ! -d "$PIGEN_REPO" ] || [ "$(git -C "$PIGEN_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "arm64" ]; then
  rm -rf "$PIGEN_REPO"
  git clone --depth 1 --branch arm64 https://github.com/RPi-Distro/pi-gen.git "$PIGEN_REPO"
else
  echo "    pi-gen arm64 already cloned, pulling latest..."
  git -C "$PIGEN_REPO" pull --ff-only || true
fi

# Copy our config into pi-gen
cp "$PIGEN_DIR/config" "$PIGEN_REPO/config"

# Copy our custom stage into pi-gen (must be a real copy, not symlink, for Docker COPY)
rm -rf "$PIGEN_REPO/stage-clawrig"
cp -a "$PIGEN_DIR/stage-clawrig" "$PIGEN_REPO/stage-clawrig"

# Skip image export for stages 0-2 (we only want the final image)
for stage in stage0 stage1 stage2; do
  touch "$PIGEN_REPO/$stage/SKIP_IMAGES"
done

# -----------------------------------------------
# Step 4: Build the image
# -----------------------------------------------
echo ""
echo "==> Step 4: Building Pi OS image (this takes 15-30 minutes)..."
cd "$PIGEN_REPO"
PRESERVE_CONTAINER=1 ./build-docker.sh

# -----------------------------------------------
# Step 5: Report
# -----------------------------------------------
echo ""
echo "============================================"
echo "  Image build complete!"
echo ""
echo "  Output: $PIGEN_REPO/deploy/"
ls -lh "$PIGEN_REPO/deploy/"
echo ""
echo "  Flash with Raspberry Pi Imager or:"
echo "    unzip deploy/clawrig-*.zip"
echo "    sudo dd if=clawrig-*.img of=/dev/<sdcard> bs=4M status=progress"
echo "============================================"
