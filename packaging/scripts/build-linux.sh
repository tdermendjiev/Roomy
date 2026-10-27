#!/usr/bin/env bash
# Build a self-contained Linux binary (static Swift stdlib + Foundation).
# Usage: packaging/scripts/build-linux.sh [arch]   (arch defaults to the host: x86_64 or aarch64)
# Output: dist/linux/<deb-arch>/roomy and dist/linux/<deb-arch>/roomy.sha256
set -euo pipefail
cd "$(dirname "$0")/../.."
ARCH="${1:-$(uname -m)}"
case "$ARCH" in
  x86_64|amd64) DEB_ARCH=amd64 ;;
  aarch64|arm64) DEB_ARCH=arm64 ;;
  *) echo "unsupported arch $ARCH" >&2; exit 1 ;;
esac
OUT="dist/linux/$DEB_ARCH"
mkdir -p "$OUT"
( cd RoomyCore && swift build -c release --product roomy --static-swift-stdlib -Xswiftc -Osize 2>&1 | grep -vE "no version information|mktemp' is dangerous" || true )
BIN="RoomyCore/.build/release/roomy"
test -x "$BIN"
strip "$BIN" 2>/dev/null || true
cp "$BIN" "$OUT/roomy"
( cd "$OUT" && sha256sum roomy > roomy.sha256 )
"$OUT/roomy" version
ls -la "$OUT/roomy"
echo "static check:"; ldd "$OUT/roomy" 2>&1 | sed 's/^/  /' | head -8
