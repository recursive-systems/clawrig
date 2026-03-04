#!/bin/bash
set -e

# Install Node.js LTS via nodesource
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt-get install -y nodejs

# Install build dependencies for native npm modules
apt-get install -y build-essential python3 make g++ cmake

# Install OpenClaw CLI globally
npm install -g openclaw@latest

# Run onboard as the pi user (uid 1000) to set up config + daemon service
# --non-interactive: no prompts
# --accept-risk: required for non-interactive
# --install-daemon: install the gateway systemd user service
su - pi -c "openclaw onboard --non-interactive --accept-risk --install-daemon"

# Verify
su - pi -c "openclaw --version"

# Pre-bake openclaw.json with model + gateway defaults.
# The wizard's OpenAI step runs `openclaw onboard --auth-choice ...` which merges
# auth config into this file. Telegram channel config is added at runtime if needed.
cat > /home/pi/.openclaw/openclaw.json << 'OCJSON'
{
  "agents": {"defaults": {"model": {"primary": "openai-codex/gpt-5.3-codex"}}},
  "gateway": {"mode": "local"}
}
OCJSON
chown 1000:1000 /home/pi/.openclaw/openclaw.json
mkdir -p /home/pi/.openclaw/agents/main/agent
chown -R 1000:1000 /home/pi/.openclaw

# Install ClawRig OpenClaw plugin (skills + clawrig-info CLI tool)
if [ -d /tmp/clawrig-plugin ]; then
    # Install skills to OpenClaw's managed skills directory
    for skill_dir in /tmp/clawrig-plugin/skills/*/; do
        skill_name=$(basename "$skill_dir")
        mkdir -p "/home/pi/.openclaw/skills/$skill_name"
        cp "$skill_dir/SKILL.md" "/home/pi/.openclaw/skills/$skill_name/SKILL.md"
    done
    chown -R 1000:1000 /home/pi/.openclaw/skills

    # Install CLI tool to /usr/local/bin (always on PATH)
    install -m 755 /tmp/clawrig-plugin/scripts/clawrig-info /usr/local/bin/clawrig-info

    rm -rf /tmp/clawrig-plugin
fi

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
