# Changelog

## 1.3.0 — 2026-10-27

The "cleans up after your agents" release. One core, three surfaces.

### New
- **`roomy` CLI** for macOS and Linux. `scan` (table or `--json`), plan-file deletion with `clean`, `purge`/`restore` for quarantine, `rules`, `doctor`. Stable, versioned JSON for agents. Exit codes that mean something.
- **Roomy Fleet**: `roomy fleet run|serve|policy|audit|license|metrics`. JSON policy files, safe-tier-only by default, quarantine with retention, hash-chained audit log, Prometheus metrics (textfile collector or built-in HTTP server), systemd units, offline Ed25519 license tokens.
- **Roomy Hub**: `roomy hub serve` is the central service hosts report to after every run. Inventory with health status (healthy / attention / stale), fleet-wide totals, freed-per-day trend, disk pressure, the largest findings across the fleet, per-host history and top findings, operator notes, an event log, a self-contained dashboard that works air-gapped, a JSON API, fleet-wide Prometheus metrics, and centrally managed policies that hosts pull before each run. Two-token auth (agent / admin), license-enforced host allowance (5 without a license), plain-file storage. `roomy hub demo` generates a synthetic fleet to try it. systemd unit and Docker usage included.
- **Linux support** in the core: freedesktop Trash, quarantine, volume space via `statvfs`, per-platform paths in the rule catalog.
- **Rule catalog as data** (`builtin-rules.json`, embedded at build time). Extra catalogs merge at runtime; rules can be disabled by id. `roomy rules --json` prints it.
- **New rules**, from measuring real machines and the agents' own issue trackers: Cursor stale agent CLI builds (the one live build is kept), Cursor state database and its backup, Cursor local history, Claude Code scratch directories, Claude CLI cache, Codex feedback log databases and crash dumps and leftover signing clones, OpenClaw plugin build captures and logs, generic Electron crash dumps, un-emptied freedesktop Trash on headless hosts, Claude Code worktrees (irreversible), Go/Cargo/Gradle/Maven/bun/deno/ccache caches, Angular/nx caches, `.terraform`, .NET `obj`.
- **Agent host leftovers** category.
- **Walk-skip list**: the project walk no longer descends into tool-owned trees (`~/.cursor-server`, `~/.nvm`, `~/Library`, …) where a `node_modules` is part of an install.

### Changed
- The scanner, probes, deletion and settings data types moved from the app into the `RoomyCore` Swift package. The app is now a front-end over it. No behaviour change in the app beyond the new rules and category.
- Fixed-path probes (Xcode DerivedData, DeviceSupport, package caches, AI tool paths) are catalog rules instead of code.

### Fixed
- Pipes from long-running child processes are drained concurrently, so a chatty `docker` or `conda` can no longer stall a probe.
