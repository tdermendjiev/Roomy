#!/usr/bin/env bash
# Sign release artifacts: SHA256SUMS + detached GPG signature. Optionally cosign for the container image.
# Usage: packaging/scripts/sign.sh dist/release/   (set GPG_KEY_ID to pick a key; skips GPG if unset)
set -euo pipefail
DIR="${1:?dir}"
cd "$DIR"
sha256sum $(ls | grep -vE '^(SHA256SUMS|.*\.asc)$') > SHA256SUMS
if [ -n "${GPG_KEY_ID:-}" ]; then
  gpg --batch --yes --local-user "$GPG_KEY_ID" --armor --detach-sign SHA256SUMS
  echo "signed SHA256SUMS with $GPG_KEY_ID"
else
  echo "GPG_KEY_ID not set; wrote SHA256SUMS only"
fi
if command -v cosign >/dev/null 2>&1 && [ -n "${COSIGN_IMAGE:-}" ]; then
  cosign sign --yes "$COSIGN_IMAGE"
fi
cat SHA256SUMS
