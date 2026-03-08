#!/bin/bash
# Layer 1: Gateway Watchdog

set -euo pipefail

CLAWRIG_USER="pi"
STATE_DIR="/var/lib/clawrig"
BACKOFF_FILE="$STATE_DIR/.watchdog-backoff"
AUTOHEAL_STATE="$STATE_DIR/autoheal-state.json"
AUTOHEAL_LOG="$STATE_DIR/autoheal-log.jsonl"
LOG_TAG="clawrig-watchdog"
MAX_BACKOFF=5

log() {
    logger -t "$LOG_TAG" "$*"
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
    log "Auto-healing disabled; skipping watchdog run"
    set_state false "unknown" "skipped" "watchdog-skip" "enabled-flag"
    log_json "enabled-flag" "watchdog-skip" "skipped" "Auto-healing disabled"
    exit 0
fi

if ! command -v openclaw &>/dev/null; then
    if [ -x "/home/$CLAWRIG_USER/.local/bin/openclaw" ]; then
        export PATH="/home/$CLAWRIG_USER/.local/bin:$PATH"
    else
        exit 0
    fi
fi

healthy=false
if sudo -u "$CLAWRIG_USER" openclaw gateway status 2>&1 | grep -q "RPC probe: ok"; then
    healthy=true
fi

if [ "$healthy" = true ]; then
    [ -f "$BACKOFF_FILE" ] && rm -f "$BACKOFF_FILE"
    set_state true "healthy" "ok" "watchdog-check" "gateway-rpc"
    log_json "gateway-rpc" "watchdog-check" "ok" "Gateway healthy"
    exit 0
fi

failures=0
[ -f "$BACKOFF_FILE" ] && failures=$(cat "$BACKOFF_FILE" 2>/dev/null || echo 0)

if [ "$failures" -ge "$MAX_BACKOFF" ]; then
    set_state true "degraded" "error" "watchdog-backoff" "gateway-rpc"
    log_json "gateway-rpc" "watchdog-backoff" "error" "Max retries reached; defer to daily repair"
    exit 0
fi

failures=$((failures + 1))
echo "$failures" > "$BACKOFF_FILE"
chown "$CLAWRIG_USER:$CLAWRIG_USER" "$BACKOFF_FILE"

if sudo -u "$CLAWRIG_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$CLAWRIG_USER")" systemctl --user restart openclaw-gateway.service 2>&1; then
    set_state true "degraded" "ok" "restart-gateway" "gateway-rpc"
    log_json "gateway-rpc" "restart-gateway" "ok" "Restart command sent (attempt $failures/$MAX_BACKOFF)"
else
    sudo -u "$CLAWRIG_USER" openclaw gateway install 2>&1 || true
    sudo -u "$CLAWRIG_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$CLAWRIG_USER")" systemctl --user enable --now openclaw-gateway.service 2>&1 || true
    set_state true "degraded" "error" "restart-failed" "gateway-rpc"
    log_json "gateway-rpc" "restart-failed" "error" "Restart/install fallback attempted"
fi
