# Linux notes

Roomy on Linux is the same `roomy` binary as on macOS, built with the Swift standard library linked statically. One file, no runtime to install, about 20 MB.

## Install

- Debian/Ubuntu: `sudo dpkg -i roomy_<version>_<arch>.deb` — installs `/usr/bin/roomy`, systemd units, `/etc/roomy/policy.json` (kept on upgrade).
- RHEL/Fedora: `sudo rpm -i roomy-<version>.<arch>.rpm`. Alpine: `apk add --allow-untrusted roomy-<version>.apk`.
- Tarball: `tar xzf roomy-<version>-linux-<arch>.tar.gz && sudo install -m 755 roomy /usr/bin/`.
- Container: `ghcr.io/tdermendjiev/roomy` — see `packaging/docker/Dockerfile`.

`roomy doctor` tells you what is missing. `du` (coreutils) is used for sizes; `git` improves project-age detection; `docker` and `conda` enable those categories.

## Trash vs quarantine

Desktop Linux has the freedesktop Trash and Roomy supports it (`--method trash`). On a **headless host nothing ever empties the Trash**, so space is never reclaimed while the user believes it was. Roomy's default there is **quarantine**: items are renamed into `~/.roomy/quarantine` (same volume, instant) with a manifest, and `roomy purge` or a fleet run with `purgeOnRun` frees them after `retentionDays`. `roomy restore` moves an item back. Items on another volume go to `<mount>/.roomy-quarantine`.

The `agentHost` category also reports an un-emptied Trash as a finding (review tier), because on agent hosts that is often gigabytes.

## Which user

Artifacts belong to the user who created them. Run Roomy as that user: `roomy-fleet@<user>.timer`. To scan a different home as root, set `scan.home` in the policy or `--home` on the CLI. Roomy respects `XDG_CACHE_HOME`, `XDG_DATA_HOME`, `HF_HOME`, `UV_CACHE_DIR`, `GOCACHE`, `TMPDIR`, `OPENCLAW_STATE_DIR` when resolving catalog paths.

## Containers

The image runs `roomy` as its entrypoint. Mount the home to clean and the policy:

```sh
docker run --rm -v /home/agent:/home/agent -v /etc/roomy:/etc/roomy:ro ghcr.io/tdermendjiev/roomy scan --home /home/agent --json
docker run -d --name roomy -p 9477:9477 -v /home/agent:/home/agent -v /etc/roomy:/etc/roomy:ro \
  ghcr.io/tdermendjiev/roomy fleet serve --listen 0.0.0.0:9477
```

Set `scan.home` to the mounted path. Mount `/var/run/docker.sock` to enable the Docker category inside the container.

## Building from source on Linux

Swift 5.9 or newer (6.x recommended). On a machine without root you can unpack the toolchain tarball from swift.org into `~/toolchains` and use it from `PATH`; SwiftPM needs `git` and `libxml2`.

```sh
cd RoomyCore && swift build -c release --product roomy --static-swift-stdlib
```

`packaging/scripts/build-linux.sh` does this, strips the binary and writes `dist/linux/<arch>/roomy` with a checksum.
