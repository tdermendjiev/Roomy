# Packaging and releases

Everything lives in `packaging/`. CI runs the same scripts (`.github/workflows/ci.yml`, `release.yml`).

## Two repositories

The private tree (`Roomy_desktop`: Mac app, landing site, EULA, license tool) is the source of truth. The public repository [github.com/tdermendjiev/Roomy](https://github.com/tdermendjiev/Roomy) holds the open-source subset: `RoomyCore/`, `docs/`, `packaging/`, the workflows, `AGENTS.md`, `CHANGELOG.md`, `THIRD_PARTY_NOTICES.md`, with its own `README.md` and `LICENSE` from `packaging/oss/`. `packaging/scripts/export-os.sh <checkout> [vX.Y.Z]` copies the subset into a clone of it, commits and tags; it refuses to run if anything private (the app, `landing/`, `tools/`, `EULA.md`, a private key) ends up in the export. Releases, the container image and the Homebrew tap are produced by the workflow **in the public repo**; `release.yml` is a no-op in the private repo.

| Artifact | How | Where |
|---|---|---|
| macOS app | Xcode archive, Developer ID, notarize (see `DISTRIBUTION.md`) | getroomy.dev downloads |
| macOS CLI (universal) | `packaging/scripts/build-macos.sh` → codesign with `$DEVELOPER_ID_APPLICATION` → notarize tarball | GitHub release, Homebrew |
| Linux CLI (static) | `packaging/scripts/build-linux.sh` (amd64, arm64) | GitHub release tarball |
| .deb / .rpm / .apk | `packaging/scripts/package-linux.sh <version> <arch>` via [nfpm](https://nfpm.goreleaser.com) and `packaging/nfpm.yaml` | GitHub release |
| Container image | `packaging/docker/Dockerfile` (multi-stage, static binary on ubuntu:24.04) | `ghcr.io/tdermendjiev/roomy` |
| Homebrew | `packaging/homebrew/roomy.rb` in the tap `tdermendjiev/homebrew-roomy` | `brew install tdermendjiev/roomy/roomy` |
| SBOM | `packaging/scripts/sbom.py <version>` (CycloneDX 1.5 from `Package.resolved`) | GitHub release |
| Checksums + signature | `packaging/scripts/sign.sh dist/release` (SHA256SUMS, GPG detached signature, optional cosign) | GitHub release |

## Release checklist

1. Bump `RoomyCoreInfo.version` (`RoomyCore/Sources/RoomyCore/RoomyCore.swift`), `MARKETING_VERSION` in the Xcode project, `catalogVersion` in `builtin-rules.json` if rules changed, `CHANGELOG.md`, the landing page version strings.
2. `cd RoomyCore && swift test`; `xcodebuild -project Roomy.xcodeproj -scheme Roomy test -only-testing:RoomyTests`.
3. `packaging/scripts/export-os.sh ../Roomy vX.Y.Z`, then push `main` and the tag to the public repo. The release workflow there builds Linux amd64/arm64 packages, the macOS universal CLI (signed and notarized when secrets are set), the container image `ghcr.io/tdermendjiev/roomy`, SBOM, checksums and signatures, creates the GitHub release and pushes the updated formula to `tdermendjiev/homebrew-roomy`.
4. If the tap job was skipped (no `HOMEBREW_TAP_TOKEN`), update `Formula/roomy.rb` in the tap by hand: `packaging/scripts/release.sh` prints the `url` and `sha256`.
5. Archive, notarize and upload the Mac app per `DISTRIBUTION.md`; deploy the landing page (`npm run deploy:landing`).

## Secrets used by CI

Set in the **public** repository (`tdermendjiev/Roomy`) (Settings → Secrets and variables → Actions): `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `DEVELOPER_ID_APPLICATION`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, `NOTARY_KEY_P8` (macOS signing/notarization), `GPG_KEY_ID`, `GPG_PRIVATE_KEY` (checksum signature), `HOMEBREW_TAP_TOKEN` (a fine-grained personal access token with *Contents: read and write* on `tdermendjiev/homebrew-roomy`). All optional; steps are skipped when unset. The container image is pushed with the workflow's own `GITHUB_TOKEN`; after the first release set the `roomy` package to public under Packages.

## systemd units

`roomy-fleet@.service` + `roomy-fleet@.timer` (oneshot every 6h, `SuccessExitStatus=4` so a held lock is not a failure) and `roomy-fleet-serve@.service` (long-running with metrics). Instance = Unix user.

`roomy-hub.service` runs the hub as a `DynamicUser` with state in `/var/lib/roomy-hub`, listen address and title from `/etc/roomy/hub.env`, tokens from `/etc/roomy/hub.agent.token` and `/etc/roomy/hub.admin.token`. The Docker image runs it with `hub serve --listen 0.0.0.0:9478 --data-dir /data` (expose 9478, mount `/data`).

## Config in packages

`/etc/roomy/policy.json` is marked `config|noreplace`: package upgrades never overwrite a tuned policy. `/etc/roomy/license.key` is read if present.
