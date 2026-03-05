#!/bin/bash
set -e

# Set hostname — uses TARGET_HOSTNAME from pi-gen config (default: clawrig)
# On first boot, clawrig-assign-identity.service will replace "clawrig"
# with a unique "clawrig-XXXX" name before the app starts.
DEVICE_HOSTNAME="${TARGET_HOSTNAME:-clawrig}"
echo "$DEVICE_HOSTNAME" > /etc/hostname
sed -i "s/127.0.1.1.*/127.0.1.1\t${DEVICE_HOSTNAME}/" /etc/hosts

# Ensure directories exist for identity service
mkdir -p /opt/clawrig/bin
mkdir -p /var/lib/clawrig

# Enable first-boot identity assignment
systemctl enable clawrig-assign-identity.service
