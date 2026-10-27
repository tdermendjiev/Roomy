#!/usr/bin/env bash
# Build a universal (arm64 + x86_64) release `roomy` for macOS, sign it with the Developer ID if present.
# Output: dist/macos/roomy, dist/macos/roomy.sha256, dist/macos/roomy-<version>-macos-universal.tar.gz
set -euo pipefail
cd "$(dirname "$0")/../.."
VERSION="$(RoomyCore/.build/release/roomy version 2>/dev/null | awk '{print $2}' || true)"
mkdir -p dist/macos
# One build per architecture, then lipo. (`swift build --arch a --arch b` uses a build path that cannot embed the rule catalog.)
( cd RoomyCore && swift build -c release --product roomy --triple arm64-apple-macosx13.0 )
( cd RoomyCore && swift build -c release --product roomy --triple x86_64-apple-macosx13.0 )
ARM_BIN="$(cd RoomyCore && swift build -c release --triple arm64-apple-macosx13.0 --show-bin-path)/roomy"
X86_BIN="$(cd RoomyCore && swift build -c release --triple x86_64-apple-macosx13.0 --show-bin-path)/roomy"
lipo -create -output dist/macos/roomy "$ARM_BIN" "$X86_BIN"
VERSION="$(dist/macos/roomy version | awk '{print $2}')"
if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" dist/macos/roomy
  echo "signed with $DEVELOPER_ID_APPLICATION (notarize: ditto -c -k dist/macos/roomy roomy.zip && xcrun notarytool submit roomy.zip --keychain-profile roomy-notary --wait)"
fi
( cd dist/macos && shasum -a 256 roomy > roomy.sha256 && tar czf "roomy-$VERSION-macos-universal.tar.gz" roomy && shasum -a 256 "roomy-$VERSION-macos-universal.tar.gz" >> roomy.sha256 )
lipo -archs dist/macos/roomy
dist/macos/roomy version
