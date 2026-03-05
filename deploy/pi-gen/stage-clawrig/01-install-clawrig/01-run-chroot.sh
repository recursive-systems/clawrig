#!/bin/bash
set -e

# Install Node.js LTS via nodesource
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt-get install -y nodejs

# Install build dependencies for native npm modules
apt-get install -y build-essential python3 make g++ cmake

# Install OpenClaw CLI globally
npm install -g openclaw@latest

# Install Codex CLI (static musl binary for aarch64 — used for self-healing diagnostics)
CODEX_ARCH="aarch64-unknown-linux-musl"
curl -fsSL "https://github.com/openai/codex/releases/latest/download/codex-${CODEX_ARCH}.tar.gz" \
  -o /tmp/codex.tar.gz
tar xzf /tmp/codex.tar.gz -C /usr/local/bin/
mv /usr/local/bin/codex-${CODEX_ARCH} /usr/local/bin/codex
chmod 755 /usr/local/bin/codex
rm -f /tmp/codex.tar.gz
codex --version || echo "Warning: codex --version failed (may need runtime auth)"

# Run onboard as the pi user (uid 1000) to set up config + daemon service.
# The gateway can't start inside a chroot, so allow failure — the critical
# outputs (directory scaffold + systemd unit) are handled below if onboard fails.
su - pi -c "openclaw onboard --non-interactive --accept-risk --install-daemon" || {
  echo "Warning: openclaw onboard failed (expected in chroot — gateway can't bind)."
  echo "Scaffolding directories manually..."
  mkdir -p /home/pi/.openclaw/agents/main/sessions
  mkdir -p /home/pi/.openclaw/workspace
  mkdir -p /home/pi/.openclaw/skills
  chown -R 1000:1000 /home/pi/.openclaw
}

# Verify
su - pi -c "openclaw --version"

# Pre-bake openclaw.json with model + gateway defaults.
# The wizard's OpenAI step runs `openclaw onboard --auth-choice ...` which merges
# auth config into this file. Telegram channel config is added at runtime if needed.
cat > /home/pi/.openclaw/openclaw.json << 'OCJSON'
{
  "agents": {"defaults": {"model": {"primary": "openai-codex/gpt-5.3-codex"}}},
  "gateway": {"mode": "local"},
  "tools": {
    "allow": ["group:messaging", "read", "exec"],
    "exec": {"host": "gateway", "security": "allowlist", "ask": "off"}
  }
}
OCJSON
chown 1000:1000 /home/pi/.openclaw/openclaw.json

# Pre-bake exec approvals with wildcard allowlist.
# Specific path patterns (e.g. "/usr/local/bin/clawrig-info*") don't reliably
# match through OpenClaw's gateway exec pipeline due to symlink resolution and
# policy layers. A dedicated appliance like ClawRig can safely use a wildcard.
cat > /home/pi/.openclaw/exec-approvals.json << 'APPROVALS'
{
  "version": 1,
  "agents": {
    "*": {
      "allowlist": [
        {"pattern": "*"}
      ]
    }
  }
}
APPROVALS
chown 1000:1000 /home/pi/.openclaw/exec-approvals.json

mkdir -p /home/pi/.openclaw/agents/main/agent
chown -R 1000:1000 /home/pi/.openclaw

# Enable user linger so user-level services persist across reboots.
# loginctl enable-linger doesn't work in chroot, so create the marker directly.
mkdir -p /var/lib/systemd/linger
touch /var/lib/systemd/linger/pi

# Pre-enable the openclaw-gateway user service.
# systemctl --user enable doesn't work in chroot, so create the symlink directly.
# The unit file was installed by `openclaw onboard --install-daemon` above.
GW_UNIT=$(find /home/pi/.config/systemd /home/pi/.local/share/systemd \
  -name "openclaw-gateway.service" 2>/dev/null | head -1)
if [ -n "$GW_UNIT" ]; then
    WANTS_DIR="$(dirname "$GW_UNIT")/default.target.wants"
    mkdir -p "$WANTS_DIR"
    ln -sf "$GW_UNIT" "$WANTS_DIR/openclaw-gateway.service"
    chown -R 1000:1000 /home/pi/.config /home/pi/.local 2>/dev/null || true
fi
