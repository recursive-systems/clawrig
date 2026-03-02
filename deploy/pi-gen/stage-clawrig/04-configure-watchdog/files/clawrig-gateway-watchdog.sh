#!/bin/bash
# Layer 1: Gateway Watchdog
#
# Checks if the openclaw-gateway user service is running and healthy.
# If not, attempts to restart it with exponential backoff.
# This script is invoked by a systemd timer every 2 minutes.

set -euo pipefail

CLAWRIG_USER="pi"
STATE_DIR="/var/lib/clawrig"
BACKOFF_FILE="$STATE_DIR/.watchdog-backoff"
LOG_TAG="clawrig-watchdog"
MAX_BACKOFF=5  # After 5 consecutive failures, stop trying and wait for daily repair

log() {
    logger -t "$LOG_TAG" "$*"
}

# Only run after OOBE is complete (gateway won't exist before that)
if [ ! -f "$STATE_DIR/.oobe-complete" ]; then
    exit 0
fi

# Check if openclaw is even installed
if ! command -v openclaw &>/dev/null; then
    # Check in common install locations
    if [ -x "/home/$CLAWRIG_USER/.local/bin/openclaw" ]; then
        export PATH="/home/$CLAWRIG_USER/.local/bin:$PATH"
    else
        exit 0  # OpenClaw not installed yet, nothing to watch
    fi
fi

# Check gateway health via `openclaw gateway status`
healthy=false
if sudo -u "$CLAWRIG_USER" openclaw gateway status 2>&1 | grep -q "RPC probe: ok"; then
    healthy=true
fi

if [ "$healthy" = true ]; then
    # Gateway is healthy — reset backoff counter
    if [ -f "$BACKOFF_FILE" ]; then
        rm -f "$BACKOFF_FILE"
        log "Gateway recovered, backoff counter reset"
    fi
    exit 0
fi

# Gateway is unhealthy — check backoff
failures=0
if [ -f "$BACKOFF_FILE" ]; then
    failures=$(cat "$BACKOFF_FILE" 2>/dev/null || echo 0)
fi

if [ "$failures" -ge "$MAX_BACKOFF" ]; then
    log "Gateway still down after $failures attempts, deferring to daily repair"
    exit 0
fi

# Increment failure counter
failures=$((failures + 1))
echo "$failures" > "$BACKOFF_FILE"
chown "$CLAWRIG_USER:$CLAWRIG_USER" "$BACKOFF_FILE"

log "Gateway unhealthy (attempt $failures/$MAX_BACKOFF), restarting..."

# Try restarting the user-level service
if sudo -u "$CLAWRIG_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$CLAWRIG_USER")" \
    systemctl --user restart openclaw-gateway.service 2>&1; then
    log "Gateway restart command sent"
else
    log "systemctl restart failed, trying openclaw gateway install + start"
    sudo -u "$CLAWRIG_USER" openclaw gateway install 2>&1 || true
    sudo -u "$CLAWRIG_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$CLAWRIG_USER")" \
        systemctl --user enable --now openclaw-gateway.service 2>&1 || true
fi
