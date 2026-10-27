# Roomy

Roomy frees the disk space that developer tools and AI agents leave behind: `node_modules`, build caches, Docker images, downloaded models, and whatever Cursor, Claude Code, Codex and Ollama cached. It knows which of it grows back, and it never deletes without a plan.

This repository is the open-source part of Roomy, for macOS and Linux:

| | |
|---|---|
| `RoomyCore/Sources/RoomyCore` | The engine: scanner, rule catalog (JSON), probes for AI tools and system caches, disposal to Trash or quarantine. Foundation only. |
| `RoomyCore/Sources/roomy` | The `roomy` CLI: scan, plan, clean, restore, purge, rules, doctor. A JSON contract made for AI agents. |
| `RoomyCore/Sources/RoomyFleet` | `roomy fleet`: policy-driven unattended cleanup with an audit log and Prometheus metrics. `roomy hub`: central inventory, dashboard and managed policies for many hosts. |
| `packaging/` | Homebrew formula, Dockerfile, nfpm spec for .deb/.rpm/.apk, systemd units, release scripts. |
| `docs/` | Reference documentation. Also at [getroomy.dev](https://getroomy.dev/documentation). |

The macOS app with the review UI is free at [getroomy.dev](https://getroomy.dev). It is built on this package but is not open source.

## Install

```sh
brew install tdermendjiev/roomy/roomy                    # macOS
```

Linux: `.deb`, `.rpm`, `.apk` and static tarballs for amd64 and arm64 are on the [Releases](https://github.com/tdermendjiev/Roomy/releases) page. Container image: `ghcr.io/tdermendjiev/roomy`. See [docs/linux.md](docs/linux.md).

## First run

```sh
roomy scan                                   # what is taking space, by safety tier
roomy scan --plan plan.json                  # a plan of the safe-tier items
roomy clean --plan plan.json --dry-run       # what would happen
roomy clean --plan plan.json --yes           # to the Trash (macOS) or quarantine (Linux)
roomy restore <path>                         # bring something back
```

Three safety tiers: **safe** is regenerable, **caution** needs `--allow-caution`, **warning** is irreversible and never automated. Details in [docs/cli.md](docs/cli.md); the contract for agents is in [docs/agents.md](docs/agents.md) and [AGENTS.md](AGENTS.md).

## Fleet and Hub

```sh
roomy fleet policy init --profile agent-host --hub http://hub.internal:9478 -o /etc/roomy/policy.json
roomy fleet run                              # scan, apply the policy, quarantine, audit, metrics
roomy hub serve --listen 0.0.0.0:9478       # inventory, dashboard, fleet-wide metrics, managed policies
roomy hub demo                               # a synthetic fleet to look at the dashboard
```

[docs/fleet.md](docs/fleet.md), [docs/policy.md](docs/policy.md), [docs/hub.md](docs/hub.md). Everything builds and runs without a license; `fleet` and `hub` run in community edition. A Fleet license sets the host allowance and attaches support, see [docs/licensing.md](docs/licensing.md).

## Build

```sh
cd RoomyCore
swift build -c release --product roomy        # .build/release/roomy
swift test
```

Swift 5.9 or newer on macOS 13 or newer, or Swift 6 on Linux. Static Linux binaries: `packaging/scripts/build-linux.sh`. Everything about releases is in [docs/packaging.md](docs/packaging.md).

## Contributing

Most useful contributions are rules. A fixed-path target is one JSON entry in `RoomyCore/Sources/RoomyCore/Rules/builtin-rules.json`, see [docs/rules.md](docs/rules.md). Run `swift test` before and after. Issues with a `roomy scan --json` excerpt are the fastest way to get a missing cache covered.

Contact: hello@getroomy.dev

## License

Copyright 2026 Azbouki. Licensed under the Apache License, Version 2.0, see [LICENSE](LICENSE).
