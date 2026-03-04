#!/usr/bin/env bash
set -euo pipefail

# Signs a ClawRig release tarball and produces manifest.json for OTA updates.
#
# Usage:
#   sign-release.sh <tarball> <version> <signing-key-pem>
#
# Example:
#   bash deploy/sign-release.sh deploy/bundle/clawrig.tar.gz 0.2.0 /tmp/signing-key.pem

if [ $# -ne 3 ]; then
  echo "Usage: $0 <tarball> <version> <signing-key-pem>" >&2
  exit 1
fi

TARBALL="$1"
VERSION="$2"
KEY_PEM="$3"

if [ ! -f "$TARBALL" ]; then
  echo "Error: tarball not found: $TARBALL" >&2
  exit 1
fi

if [ ! -f "$KEY_PEM" ]; then
  echo "Error: signing key not found: $KEY_PEM" >&2
  exit 1
fi

TARBALL_NAME=$(basename "$TARBALL")
CHECKSUM=$(sha256sum "$TARBALL" | awk '{print $1}')
SIGNATURE=$(openssl pkeyutl -sign -inkey "$KEY_PEM" -rawin -in "$TARBALL" | base64 -w0)
RELEASED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

MANIFEST_DIR=$(dirname "$TARBALL")
MANIFEST_PATH="$MANIFEST_DIR/manifest.json"

cat > "$MANIFEST_PATH" <<EOF
{
  "version": "$VERSION",
  "tarball": "$TARBALL_NAME",
  "signature": "$SIGNATURE",
  "checksum": "$CHECKSUM",
  "released_at": "$RELEASED_AT"
}
EOF

echo "manifest.json written to $MANIFEST_PATH"
echo "  version:    $VERSION"
echo "  tarball:    $TARBALL_NAME"
echo "  checksum:   $CHECKSUM"
echo "  released:   $RELEASED_AT"
