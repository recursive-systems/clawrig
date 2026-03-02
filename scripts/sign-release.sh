#!/usr/bin/env bash
set -euo pipefail

# Usage: scripts/sign-release.sh <tarball> <private-key-path> <version>
# Outputs: manifest.json in the same directory as the tarball

TARBALL="${1:?Usage: sign-release.sh <tarball> <private-key-path> <version>}"
PRIVKEY="${2:?Usage: sign-release.sh <tarball> <private-key-path> <version>}"
VERSION="${3:?Usage: sign-release.sh <tarball> <private-key-path> <version>}"

DIR="$(dirname "$TARBALL")"
BASENAME="$(basename "$TARBALL")"

# Generate SHA256 checksum
CHECKSUM=$(shasum -a 256 "$TARBALL" | awk '{print $1}')

# Sign with Ed25519
SIGNATURE=$(openssl pkeyutl -sign -inkey "$PRIVKEY" -rawin -in "$TARBALL" | base64)

# Write manifest
cat > "$DIR/manifest.json" <<EOF
{
  "version": "$VERSION",
  "tarball": "$BASENAME",
  "signature": "$SIGNATURE",
  "checksum": "$CHECKSUM",
  "released_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "Manifest written to $DIR/manifest.json"
echo "  Version:  $VERSION"
echo "  Checksum: $CHECKSUM"
