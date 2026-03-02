#!/bin/bash
# Layer 2: Daily Self-Repair
#
# Runs at 5 AM daily to catch config drift, stale caches, dependency issues,
# and any problems the watchdog couldn't fix with a simple restart.

set -euo pipefail

CLAWRIG_USER="pi"
STATE_DIR="/var/lib/clawrig"
LOG_TAG="clawrig-daily-repair"
REPAIR_LOG="$STATE_DIR/daily-repair.log"

log() {
    logger -t "$LOG_TAG" "$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$REPAIR_LOG"
}

# Only run after OOBE is complete
if [ ! -f "$STATE_DIR/.oobe-complete" ]; then
    exit 0
fi

log "=== Daily repair starting ==="

# Rotate repair log (keep last 7 days)
if [ -f "$REPAIR_LOG" ] && [ "$(wc -l < "$REPAIR_LOG")" -gt 500 ]; then
    tail -200 "$REPAIR_LOG" > "$REPAIR_LOG.tmp"
    mv "$REPAIR_LOG.tmp" "$REPAIR_LOG"
fi

# Find openclaw binary
OPENCLAW_BIN="openclaw"
if ! command -v openclaw &>/dev/null; then
    if [ -x "/home/$CLAWRIG_USER/.local/bin/openclaw" ]; then
        OPENCLAW_BIN="/home/$CLAWRIG_USER/.local/bin/openclaw"
    else
        log "OpenClaw not found, skipping repair"
        exit 0
    fi
fi

# Step 1: Run openclaw doctor --fix
log "Running openclaw doctor..."
if sudo -u "$CLAWRIG_USER" "$OPENCLAW_BIN" doctor 2>&1 | tee -a "$REPAIR_LOG"; then
    log "Doctor check passed"
else
    log "Doctor reported issues, attempting fix..."
    sudo -u "$CLAWRIG_USER" "$OPENCLAW_BIN" doctor --fix 2>&1 | tee -a "$REPAIR_LOG" || true
fi

# Step 2: Check gateway status and restart if needed
log "Checking gateway status..."
if ! sudo -u "$CLAWRIG_USER" "$OPENCLAW_BIN" gateway status 2>&1 | grep -q "RPC probe: ok"; then
    log "Gateway not healthy, reinstalling and restarting..."
    sudo -u "$CLAWRIG_USER" "$OPENCLAW_BIN" gateway install 2>&1 | tee -a "$REPAIR_LOG" || true
    sudo -u "$CLAWRIG_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$CLAWRIG_USER")" \
        systemctl --user restart openclaw-gateway.service 2>&1 | tee -a "$REPAIR_LOG" || true

    # Verify it came back
    sleep 5
    if sudo -u "$CLAWRIG_USER" "$OPENCLAW_BIN" gateway status 2>&1 | grep -q "RPC probe: ok"; then
        log "Gateway recovered after reinstall"
    else
        log "WARNING: Gateway still unhealthy after repair attempt"
    fi
else
    log "Gateway healthy"
fi

# Step 3: Reset watchdog backoff counter (daily repair is the escalation point)
if [ -f "$STATE_DIR/.watchdog-backoff" ]; then
    rm -f "$STATE_DIR/.watchdog-backoff"
    log "Watchdog backoff counter reset"
fi

# Step 4: Clean up stale temp files
find /tmp/openclaw -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true

# Step 5: Check disk space (warn if <500MB free)
avail_kb=$(df /opt/clawrig --output=avail | tail -1 | tr -d ' ')
if [ "$avail_kb" -lt 512000 ]; then
    log "WARNING: Low disk space - ${avail_kb}KB available"
    # Try to free space
    sudo -u "$CLAWRIG_USER" "$OPENCLAW_BIN" cache clear 2>/dev/null || true
    journalctl --vacuum-time=3d 2>/dev/null || true
    apt-get clean 2>/dev/null || true
    log "Attempted disk cleanup"
fi

log "=== Daily repair complete ==="
