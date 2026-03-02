#!/bin/bash
set -e

# Disable dnsmasq auto-start (managed by hotspot flow)
systemctl disable dnsmasq

# Enable avahi for mDNS (clawrig.local)
systemctl enable avahi-daemon

# Pre-populate iptables rules file for captive portal redirect (port 80 -> 4090)
# These get loaded at boot by iptables-persistent/netfilter-persistent
mkdir -p /etc/iptables
cat > /etc/iptables/rules.v4 << 'IPTABLES'
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A PREROUTING -i wlan0 -p tcp --dport 80 -j REDIRECT --to-port 4090
COMMIT
IPTABLES
