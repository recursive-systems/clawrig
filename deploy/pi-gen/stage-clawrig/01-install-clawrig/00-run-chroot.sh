#!/bin/bash
set -e

# Untar the pre-built release
mkdir -p /opt/clawrig
tar xzf /tmp/clawrig.tar.gz -C /opt/clawrig --strip-components=1
chown -R 1000:1000 /opt/clawrig
if [ -f /opt/clawrig/plugins/clawrig/bin/clawrig-info ]; then
  ln -sf /opt/clawrig/plugins/clawrig/bin/clawrig-info /usr/local/bin/clawrig-info
fi
rm /tmp/clawrig.tar.gz

# Generate SECRET_KEY_BASE
SECRET=$(openssl rand -hex 64)
echo "SECRET_KEY_BASE=$SECRET" > /etc/clawrig.env
chmod 600 /etc/clawrig.env

# Create config directory (pubkey + token stored here)
mkdir -p /etc/clawrig

# Create state directory
mkdir -p /var/lib/clawrig
chown 1000:1000 /var/lib/clawrig

# Install systemd service
cp /tmp/clawrig.service /etc/systemd/system/
systemctl enable clawrig
rm /tmp/clawrig.service
