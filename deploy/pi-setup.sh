#!/usr/bin/env bash
set -e

# Usage: scp this script + clawrig.tar.gz to the Pi, then run:
#   bash pi-setup.sh [HOSTNAME]
#
# HOSTNAME is optional. Examples:
#   bash pi-setup.sh                   # auto-generates clawrig-a3f7 (random 4-hex)
#   bash pi-setup.sh clawrig-kitchen   # uses the given name
#   bash pi-setup.sh clawrig-dev       # uses the given name
#
# Expects clawrig.tar.gz in the same directory as this script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARBALL="$SCRIPT_DIR/clawrig.tar.gz"

# Determine hostname: use argument, or generate a unique one
if [ -n "$1" ]; then
  DEVICE_HOSTNAME="$1"
else
  SHORT_ID=$(head -c 2 /dev/urandom | od -A n -t x1 | tr -d ' \n')
  DEVICE_HOSTNAME="clawrig-${SHORT_ID}"
fi

echo "============================================"
echo "  ClawRig OOBE - Raspberry Pi Setup"
echo "  Device: ${DEVICE_HOSTNAME}"
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

# Remove old wlan0-only rule if present
sudo iptables -t nat -D PREROUTING -i wlan0 -p tcp --dport 80 -j REDIRECT --to-port 4090 2>/dev/null || true
# Add all-interface rule (matches golden image config)
sudo iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 4090 2>/dev/null \
  || sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 4090
sudo netfilter-persistent save

# 5. Configure mDNS (avahi)
echo ""
echo "==> Configuring mDNS (${DEVICE_HOSTNAME}.local)..."
sudo hostnamectl set-hostname "$DEVICE_HOSTNAME"
sudo sed -i "s/127.0.1.1.*/127.0.1.1\t${DEVICE_HOSTNAME}/" /etc/hosts
sudo mkdir -p /etc/avahi/services
# Generate avahi service file with device-specific name
sudo tee /etc/avahi/services/clawrig.service > /dev/null << AVAHI
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name>${DEVICE_HOSTNAME}</name>
  <service>
    <type>_http._tcp</type>
    <port>4090</port>
  </service>
</service-group>
AVAHI
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

# Configure exec tool for gateway (full security, no prompts)
python3 -c "
import json, os
cfg_path = '/home/pi/.openclaw/openclaw.json'
if os.path.exists(cfg_path):
    with open(cfg_path) as f:
        cfg = json.load(f)
    tools = cfg.setdefault('tools', {})
    tools.pop('profile', None)
    tools['allow'] = ['group:messaging', 'read', 'exec']
    tools['exec'] = {'host': 'gateway', 'security': 'full', 'ask': 'off'}
    with open(cfg_path, 'w') as f:
        json.dump(cfg, f, indent=2)
    os.chown(cfg_path, 1000, 1000)
"

# Pre-bake exec approvals with wildcard allowlist (dedicated appliance)
cat > /home/pi/.openclaw/exec-approvals.json << 'APPROVALS'
{
  "version": 1,
  "agents": {
    "*": {
      "allowlist": [
        {"pattern": "*"}
      ]
    }
  }
}
APPROVALS
chown pi:pi /home/pi/.openclaw/exec-approvals.json

# 7. Install systemd service + first-boot identity assignment
echo ""
echo "==> Installing systemd services..."
sudo cp "$SCRIPT_DIR/clawrig.service" /etc/systemd/system/
sudo mkdir -p /opt/clawrig/bin
sudo install -m 755 "$SCRIPT_DIR/clawrig-assign-identity.sh" /opt/clawrig/bin/clawrig-assign-identity.sh
sudo cp "$SCRIPT_DIR/clawrig-assign-identity.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable clawrig
sudo systemctl enable clawrig-assign-identity.service

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

# Derive SSID from hostname (matches Clawrig.DeviceIdentity logic)
SUFFIX=$(echo "$DEVICE_HOSTNAME" | sed 's/^clawrig-//')
if [ "$SUFFIX" != "$DEVICE_HOSTNAME" ]; then
  SSID="ClawRig-$(echo "$SUFFIX" | tr '[:lower:]' '[:upper:]')-Setup"
else
  SSID="ClawRig-Setup"
fi

echo ""
echo "============================================"
echo "  Setup complete!"
echo "  Device hostname: ${DEVICE_HOSTNAME}"
echo "  mDNS address:    ${DEVICE_HOSTNAME}.local"
echo "  Hotspot SSID:    ${SSID}"
echo ""
echo "  Reboot to start the OOBE wizard:"
echo "    sudo reboot"
echo ""
echo "  After reboot, connect to '${SSID}' WiFi."
echo ""
echo "  Self-healing enabled:"
echo "    - Hardware watchdog (auto-reboot on hang)"
echo "    - Gateway watchdog (checks every 2 min)"
echo "    - Daily repair (5 AM, openclaw doctor)"
echo "============================================"
