#!/usr/bin/env bash
# Local release driver. CI (.github/workflows/release.yml) runs the same steps.
#   packaging/scripts/release.sh 1.3.0
# Produces dist/release/ with the macOS tarball (if on macOS), Linux binary, packages, SBOM, checksums.
set -euo pipefail
cd "$(dirname "$0")/../.."
VERSION="${1:?version}"
rm -rf dist/release && mkdir -p dist/release
case "$(uname -s)" in
  Darwin)
    packaging/scripts/build-macos.sh
    cp dist/macos/roomy-"$VERSION"-macos-universal.tar.gz dist/release/
    ;;
  Linux)
    packaging/scripts/build-linux.sh
    ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
    tar czf "dist/release/roomy-$VERSION-linux-$ARCH.tar.gz" -C "dist/linux/$ARCH" roomy
    if command -v nfpm >/dev/null 2>&1; then
      packaging/scripts/package-linux.sh "$VERSION" "$ARCH"
      cp dist/packages/* dist/release/
    else
      echo "nfpm not found; skipping .deb/.rpm/.apk (install: https://nfpm.goreleaser.com/install/)"
    fi
    ;;
esac
packaging/scripts/sbom.py "$VERSION" > "dist/release/roomy-$VERSION.cdx.json"
packaging/scripts/sign.sh dist/release
echo
echo "Homebrew: update packaging/homebrew/roomy.rb url to v$VERSION and sha256 of the source tarball:"
echo "  curl -sL https://github.com/tdermendjiev/Roomy/archive/refs/tags/v$VERSION.tar.gz | shasum -a 256"
