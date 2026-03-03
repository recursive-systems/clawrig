#!/bin/bash
set -e

# Ensure WiFi radio is not administratively blocked.
# pi-gen's stage2/02-net-tweaks writes WirelessEnabled=false to NetworkManager.state
# when WPA_COUNTRY is unset. Remove it so the hotspot can start on first boot.
rm -f /var/lib/NetworkManager/NetworkManager.state

# Allow netdev group (pi user) to manage NetworkManager without interactive auth.
# Required for the headless hotspot setup run by the clawrig systemd service.
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/50-clawrig-network.rules << 'POLKIT'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") === 0 &&
        subject.isInGroup("netdev")) {
        return polkit.Result.YES;
    }
});
POLKIT

# Disable dnsmasq auto-start (managed by hotspot flow)
systemctl disable dnsmasq

# Enable avahi for mDNS (clawrig.local)
systemctl enable avahi-daemon

# Pre-populate iptables rules file for port 80 -> 4090 redirect.
# Applies to all interfaces so clawrig.local:80 works over ethernet and WiFi.
# These get loaded at boot by iptables-persistent/netfilter-persistent.
mkdir -p /etc/iptables
cat > /etc/iptables/rules.v4 << 'IPTABLES'
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 4090
COMMIT
IPTABLES
