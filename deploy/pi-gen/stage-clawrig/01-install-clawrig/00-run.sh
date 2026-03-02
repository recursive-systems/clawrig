#!/bin/bash
set -e

# Copy the release tarball and service file into the chroot for the next script
install -m 644 files/clawrig.tar.gz "${ROOTFS_DIR}/tmp/clawrig.tar.gz"
install -m 644 files/clawrig.service "${ROOTFS_DIR}/tmp/clawrig.service"
