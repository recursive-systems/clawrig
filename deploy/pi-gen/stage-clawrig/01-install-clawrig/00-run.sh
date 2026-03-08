#!/bin/bash
set -e

# Copy the release tarball and service file into the chroot for the next script
install -m 644 files/clawrig.tar.gz "${ROOTFS_DIR}/tmp/clawrig.tar.gz"
install -m 644 files/clawrig.service "${ROOTFS_DIR}/tmp/clawrig.service"

# OTA update infrastructure: pubkey for signature verification + sudoers for updater
mkdir -p "${ROOTFS_DIR}/etc/clawrig"
if [ -f files/update-pubkey.pem ]; then
  install -m 644 files/update-pubkey.pem "${ROOTFS_DIR}/etc/clawrig/update-pubkey"
fi
install -m 440 files/clawrig-updater-sudoers "${ROOTFS_DIR}/etc/sudoers.d/clawrig-updater"

