#!/usr/bin/env bash
set -e

# Usage: scp this script + clawrig.tar.gz to the Pi, then run:
#   bash pi-setup.sh
#
# Expects clawrig.tar.gz in the same directory as this script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARBALL="$SCRIPT_DIR/clawrig.tar.gz"

echo "============================================"
echo "  ClawRig OOBE - Raspberry Pi Setup"
echo "============================================"

if [ ! -f "$TARBALL" ]; then
  echo "Error: $TARBALL not found."
  echo "Build it first with: deploy/build-release.sh"
  exit 1
fi

# 1. Install system deps (no Erlang/Elixir needed!)
echo ""
echo "==> Installing system dependencies..."
sudo apt update && sudo apt install -y \
  dnsmasq avahi-daemon iptables-persistent

# 2. Untar pre-built release
echo ""
echo "==> Installing release to /opt/clawrig..."
sudo mkdir -p /opt/clawrig
sudo tar xzf "$TARBALL" -C /opt/clawrig --strip-components=1
sudo chown -R pi:pi /opt/clawrig

# 3. Generate SECRET_KEY_BASE (using openssl, no mix needed)
echo ""
echo "==> Generating SECRET_KEY_BASE..."
SECRET=$(openssl rand -hex 64)
sudo bash -c "echo 'SECRET_KEY_BASE=$SECRET' > /etc/clawrig.env"
sudo chmod 600 /etc/clawrig.env

# 4. Configure captive portal (dnsmasq + iptables)
echo ""
echo "==> Configuring captive portal..."
sudo cp "$SCRIPT_DIR/dnsmasq-captive.conf" /etc/dnsmasq.d/clawrig-captive.conf
sudo systemctl disable dnsmasq
sudo systemctl stop dnsmasq || true

sudo iptables -t nat -C PREROUTING -i wlan0 -p tcp --dport 80 -j REDIRECT --to-port 4090 2>/dev/null \
  || sudo iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 80 -j REDIRECT --to-port 4090
sudo netfilter-persistent save

# 5. Configure mDNS (avahi)
echo ""
echo "==> Configuring mDNS (clawrig.local)..."
sudo hostnamectl set-hostname clawrig
sudo mkdir -p /etc/avahi/services
sudo cp "$SCRIPT_DIR/clawrig-avahi.service" /etc/avahi/services/clawrig.service
sudo systemctl enable avahi-daemon

# 6. Create state + config directories
echo ""
echo "==> Creating state and config directories..."
sudo mkdir -p /var/lib/clawrig
sudo chown pi:pi /var/lib/clawrig
sudo mkdir -p /etc/clawrig

# Install OTA update pubkey if present in bundle
if [ -f "$SCRIPT_DIR/update-pubkey.pem" ]; then
  echo "==> Installing OTA update pubkey..."
  sudo install -m 644 "$SCRIPT_DIR/update-pubkey.pem" /etc/clawrig/update-pubkey
fi

# Install sudoers dropin for OTA updater
if [ -f "$SCRIPT_DIR/clawrig-updater-sudoers" ]; then
  echo "==> Installing OTA updater sudoers..."
  sudo install -m 440 "$SCRIPT_DIR/clawrig-updater-sudoers" /etc/sudoers.d/clawrig-updater
fi

# Install ClawRig OpenClaw plugin
if [ -d "$SCRIPT_DIR/clawrig-plugin" ]; then
  echo "==> Installing ClawRig OpenClaw plugin..."
  # Install skills to OpenClaw's managed skills directory
  for skill_dir in "$SCRIPT_DIR"/clawrig-plugin/skills/*/; do
    skill_name=$(basename "$skill_dir")
    mkdir -p "/home/pi/.openclaw/skills/$skill_name"
    cp "$skill_dir/SKILL.md" "/home/pi/.openclaw/skills/$skill_name/SKILL.md"
  done
  chown -R pi:pi /home/pi/.openclaw/skills
  # Install CLI tool to /usr/local/bin (always on PATH)
  sudo install -m 755 "$SCRIPT_DIR/clawrig-plugin/scripts/clawrig-info" /usr/local/bin/clawrig-info

  # Configure exec tool for skill commands (gateway host, allowlist, no prompts)
  python3 -c "
import json, os
cfg_path = '/home/pi/.openclaw/openclaw.json'
with open(cfg_path) as f:
    cfg = json.load(f)
tools = cfg.setdefault('tools', {})
tools.setdefault('profile', 'messaging')
tools.setdefault('allow', ['read', 'exec'])
tools.setdefault('exec', {'host': 'gateway', 'security': 'allowlist', 'ask': 'off'})
with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2)
"
  chown pi:pi /home/pi/.openclaw/openclaw.json

  # Pre-bake exec approvals for clawrig-info
  cat > /home/pi/.openclaw/exec-approvals.json << 'APPROVALS'
{
  "version": 1,
  "allowlist": [
    {"agent": "*", "pattern": "/usr/local/bin/clawrig-info*"},
    {"agent": "*", "pattern": "clawrig-info*"}
  ]
}
APPROVALS
  chown pi:pi /home/pi/.openclaw/exec-approvals.json
fi

# 7. Install systemd service
echo ""
echo "==> Installing systemd service..."
sudo cp "$SCRIPT_DIR/clawrig.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable clawrig

# 8. Configure hardware watchdog + self-healing
echo ""
echo "==> Configuring watchdog and self-healing..."

# Layer 0: Hardware watchdog
sudo mkdir -p /etc/systemd/system.conf.d
sudo tee /etc/systemd/system.conf.d/watchdog.conf > /dev/null << 'WATCHDOG'
[Manager]
RuntimeWatchdogSec=14
RebootWatchdogSec=10min
WATCHDOG

# Layer 1: Gateway watchdog (checks every 2 min)
sudo install -m 755 "$SCRIPT_DIR/clawrig-gateway-watchdog.sh" /opt/clawrig/bin/clawrig-gateway-watchdog.sh
sudo cp "$SCRIPT_DIR/clawrig-gateway-watchdog.service" /etc/systemd/system/
sudo cp "$SCRIPT_DIR/clawrig-gateway-watchdog.timer" /etc/systemd/system/
sudo systemctl enable clawrig-gateway-watchdog.timer

# Layer 2: Daily self-repair (runs at 5 AM)
sudo install -m 755 "$SCRIPT_DIR/clawrig-daily-repair.sh" /opt/clawrig/bin/clawrig-daily-repair.sh
sudo cp "$SCRIPT_DIR/clawrig-daily-repair.service" /etc/systemd/system/
sudo cp "$SCRIPT_DIR/clawrig-daily-repair.timer" /etc/systemd/system/
sudo systemctl enable clawrig-daily-repair.timer

sudo systemctl daemon-reload

echo ""
echo "============================================"
echo "  Setup complete!"
echo "  Reboot to start the OOBE wizard:"
echo "    sudo reboot"
echo ""
echo "  After reboot, connect to 'ClawRig-Setup' WiFi."
echo ""
echo "  Self-healing enabled:"
echo "    - Hardware watchdog (auto-reboot on hang)"
echo "    - Gateway watchdog (checks every 2 min)"
echo "    - Daily repair (5 AM, openclaw doctor)"
echo "============================================"
