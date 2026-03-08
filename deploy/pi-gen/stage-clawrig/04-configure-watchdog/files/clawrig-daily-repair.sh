#!/bin/bash
# Layer 2: Daily Self-Repair

set -euo pipefail

CLAWRIG_USER="pi"
STATE_DIR="/var/lib/clawrig"
LOG_TAG="clawrig-daily-repair"
REPAIR_LOG="$STATE_DIR/daily-repair.log"
AUTOHEAL_STATE="$STATE_DIR/autoheal-state.json"
AUTOHEAL_LOG="$STATE_DIR/autoheal-log.jsonl"

log() {
    logger -t "$LOG_TAG" "$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$REPAIR_LOG"
}

log_json() {
    local check="$1" action="$2" result="$3" detail="$4"
    mkdir -p "$STATE_DIR"
    printf '{"ts":"%s","check":"%s","action":"%s","result":"%s","detail":%s}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$check" "$action" "$result" "$(printf '%s' "$detail" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" >> "$AUTOHEAL_LOG"
}

set_state() {
    local enabled="$1" health="$2" result="$3" action="$4" check="$5"
    mkdir -p "$STATE_DIR"
    cat > "$AUTOHEAL_STATE" <<EOF
{"enabled":$enabled,"health":"$health","last_result":"$result","last_action":"$action","last_check":"$check","last_run_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
}

is_enabled() {
    if [ ! -f "$AUTOHEAL_STATE" ]; then
        echo true
        return
    fi
    python3 - <<'PY' "$AUTOHEAL_STATE"
import json,sys
p=sys.argv[1]
try:
  data=json.load(open(p))
  print('false' if data.get('enabled') is False else 'true')
except Exception:
  print('true')
PY
}

if [ ! -f "$STATE_DIR/.oobe-complete" ]; then
    exit 0
fi

if [ "$(is_enabled)" = "false" ]; then
    set_state false "unknown" "skipped" "daily-repair-skip" "enabled-flag"
    log_json "enabled-flag" "daily-repair-skip" "skipped" "Auto-healing disabled"
    exit 0
fi

log "=== Daily repair starting ==="

if [ -f "$REPAIR_LOG" ] && [ "$(wc -l < "$REPAIR_LOG")" -gt 500 ]; then
    tail -200 "$REPAIR_LOG" > "$REPAIR_LOG.tmp"
    mv "$REPAIR_LOG.tmp" "$REPAIR_LOG"
fi

OPENCLAW_BIN="openclaw"
if ! command -v openclaw &>/dev/null; then
    if [ -x "/home/$CLAWRIG_USER/.local/bin/openclaw" ]; then
        OPENCLAW_BIN="/home/$CLAWRIG_USER/.local/bin/openclaw"
    else
        log "OpenClaw not found, skipping repair"
        exit 0
    fi
fi

log "Running openclaw doctor..."
if sudo -u "$CLAWRIG_USER" "$OPENCLAW_BIN" doctor 2>&1 | tee -a "$REPAIR_LOG"; then
    log "Doctor check passed"
else
    log "Doctor reported issues, attempting fix..."
    sudo -u "$CLAWRIG_USER" "$OPENCLAW_BIN" doctor --fix 2>&1 | tee -a "$REPAIR_LOG" || true
fi

log "Checking gateway status..."
if ! sudo -u "$CLAWRIG_USER" "$OPENCLAW_BIN" gateway status 2>&1 | grep -q "RPC probe: ok"; then
    log "Gateway not healthy, reinstalling and restarting..."
    sudo -u "$CLAWRIG_USER" "$OPENCLAW_BIN" gateway install 2>&1 | tee -a "$REPAIR_LOG" || true
    sudo -u "$CLAWRIG_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$CLAWRIG_USER")" systemctl --user restart openclaw-gateway.service 2>&1 | tee -a "$REPAIR_LOG" || true

    sleep 5
    if sudo -u "$CLAWRIG_USER" "$OPENCLAW_BIN" gateway status 2>&1 | grep -q "RPC probe: ok"; then
        set_state true "healthy" "ok" "daily-repair-recover" "gateway-rpc"
        log_json "gateway-rpc" "daily-repair-recover" "ok" "Gateway recovered after reinstall"
    else
        set_state true "degraded" "error" "daily-repair-failed" "gateway-rpc"
        log_json "gateway-rpc" "daily-repair-failed" "error" "Gateway still unhealthy after repair attempt"
    fi
else
    set_state true "healthy" "ok" "daily-repair-check" "gateway-rpc"
    log_json "gateway-rpc" "daily-repair-check" "ok" "Gateway healthy"
fi

[ -f "$STATE_DIR/.watchdog-backoff" ] && rm -f "$STATE_DIR/.watchdog-backoff"
find /tmp/openclaw -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true

log "=== Daily repair complete ==="
