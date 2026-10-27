#!/usr/bin/env bash
# Produce .deb, .rpm and .apk with nfpm. Needs dist/linux/<arch>/roomy (build-linux.sh) and nfpm on PATH.
# Usage: packaging/scripts/package-linux.sh <version> [deb-arch]
set -euo pipefail
cd "$(dirname "$0")/../.."
export VERSION="${1:?version}"
export ARCH="${2:-amd64}"
test -x "dist/linux/$ARCH/roomy"
mkdir -p dist/packages
# nfpm expands ${VAR} in top-level fields but not in content globs; substitute ourselves.
SPEC="$(mktemp)"
sed "s|\${ARCH}|$ARCH|g; s|\${VERSION}|$VERSION|g" packaging/nfpm.yaml > "$SPEC"
for fmt in deb rpm apk; do
  nfpm package -f "$SPEC" -p "$fmt" -t dist/packages/
done
rm -f "$SPEC"
( cd dist/packages && sha256sum roomy_* roomy-* 2>/dev/null > SHA256SUMS || sha256sum * > SHA256SUMS )
ls -la dist/packages
