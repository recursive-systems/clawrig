#!/usr/bin/env bash
# Assign a unique device identity on first boot.
# Runs once before clawrig.service starts. If the hostname is still the
# default "clawrig", generate "clawrig-XXXX" (4 random hex chars).
set -e

CURRENT=$(hostname)

if [ "$CURRENT" = "clawrig" ]; then
  SHORT_ID=$(head -c 2 /dev/urandom | od -A n -t x1 | tr -d ' \n')
  NEW_HOSTNAME="clawrig-${SHORT_ID}"

  hostnamectl set-hostname "$NEW_HOSTNAME"
  sed -i "s/127.0.1.1.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts

  # Restart avahi so mDNS advertises the new name
  systemctl restart avahi-daemon

  echo "ClawRig identity assigned: $NEW_HOSTNAME"
else
  echo "ClawRig identity already set: $CURRENT"
fi
