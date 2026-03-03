#!/bin/bash
set -e

# Copy dnsmasq and avahi config files into the chroot
install -m 644 files/dnsmasq-captive.conf "${ROOTFS_DIR}/etc/dnsmasq.d/clawrig-captive.conf"

mkdir -p "${ROOTFS_DIR}/etc/avahi/services"
install -m 644 files/clawrig-avahi.service "${ROOTFS_DIR}/etc/avahi/services/clawrig.service"

# DNS catch-all for captive portal detection (used by NM's shared dnsmasq)
mkdir -p "${ROOTFS_DIR}/etc/NetworkManager/dnsmasq-shared.d"
echo 'address=/#/192.168.4.1' > "${ROOTFS_DIR}/etc/NetworkManager/dnsmasq-shared.d/captive-portal.conf"
