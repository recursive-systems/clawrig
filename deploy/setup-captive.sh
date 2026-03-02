#!/usr/bin/env bash
set -e

echo "==> Installing captive portal dependencies..."
sudo apt install -y dnsmasq iptables-persistent

echo "==> Copying dnsmasq config..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sudo cp "$SCRIPT_DIR/dnsmasq-captive.conf" /etc/dnsmasq.d/clawrig-captive.conf

echo "==> Adding iptables redirect (port 80 -> 4090)..."
sudo iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 80 -j REDIRECT --to-port 4090
sudo netfilter-persistent save

echo "==> Disabling dnsmasq auto-start (managed by hotspot flow)..."
sudo systemctl disable dnsmasq
sudo systemctl stop dnsmasq

echo "Captive portal setup complete."
