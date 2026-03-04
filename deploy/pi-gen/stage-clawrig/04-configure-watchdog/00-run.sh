#!/bin/bash
set -e

# -----------------------------------------------
# Layer 0: Hardware Watchdog
# -----------------------------------------------
# Enable the BCM2835 hardware watchdog timer.
# If systemd fails to send heartbeats within 14s, the hardware forces a full reboot.
# This catches kernel hangs, complete system freezes, etc.
mkdir -p "${ROOTFS_DIR}/etc/systemd/system.conf.d"
cat > "${ROOTFS_DIR}/etc/systemd/system.conf.d/watchdog.conf" << 'WATCHDOG'
[Manager]
RuntimeWatchdogSec=14
RebootWatchdogSec=10min
WATCHDOG

# -----------------------------------------------
# Layer 1: Gateway Restart Wrapper
# -----------------------------------------------
# The openclaw-gateway.service is a user-level service created by `openclaw gateway install`.
# We don't control that unit file, but we can add a system-level service that monitors it
# and restarts it if it goes down. This runs as a system service watching the user service.
install -m 755 files/clawrig-gateway-watchdog.sh "${ROOTFS_DIR}/opt/clawrig/bin/clawrig-gateway-watchdog.sh"
install -m 644 files/clawrig-gateway-watchdog.service "${ROOTFS_DIR}/etc/systemd/system/clawrig-gateway-watchdog.service"
install -m 644 files/clawrig-gateway-watchdog.timer "${ROOTFS_DIR}/etc/systemd/system/clawrig-gateway-watchdog.timer"

# -----------------------------------------------
# Layer 2: Daily Self-Repair
# -----------------------------------------------
install -m 755 files/clawrig-daily-repair.sh "${ROOTFS_DIR}/opt/clawrig/bin/clawrig-daily-repair.sh"
install -m 644 files/clawrig-daily-repair.service "${ROOTFS_DIR}/etc/systemd/system/clawrig-daily-repair.service"
install -m 644 files/clawrig-daily-repair.timer "${ROOTFS_DIR}/etc/systemd/system/clawrig-daily-repair.timer"

# -----------------------------------------------
# Layer 2.5: AI Diagnostic Agent (Codex CLI)
# -----------------------------------------------
# Schema file for structured diagnostic output.
# The diagnostic agent runs inside the ClawRig Elixir app (GenServer),
# not as a separate systemd unit.
mkdir -p "${ROOTFS_DIR}/opt/clawrig/share"
install -m 644 files/diagnostic-schema.json "${ROOTFS_DIR}/opt/clawrig/share/diagnostic-schema.json"
