#!/bin/bash
set -e

# Copy dnsmasq and avahi config files into the chroot
install -m 644 files/dnsmasq-captive.conf "${ROOTFS_DIR}/etc/dnsmasq.d/clawrig-captive.conf"

mkdir -p "${ROOTFS_DIR}/etc/avahi/services"
install -m 644 files/clawrig-avahi.service "${ROOTFS_DIR}/etc/avahi/services/clawrig.service"
