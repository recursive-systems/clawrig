#!/bin/bash
set -e

# Install identity assignment script and systemd service
install -m 755 files/clawrig-assign-identity.sh "${ROOTFS_DIR}/opt/clawrig/bin/clawrig-assign-identity.sh"
install -m 644 files/clawrig-assign-identity.service "${ROOTFS_DIR}/etc/systemd/system/clawrig-assign-identity.service"
