# Architecture

Roomy is **one core with two front-ends**. The core knows how to find, classify and dispose of artifacts. It knows nothing about SwiftUI, terminals, or Prometheus.

```
┌───────────────┐  ┌──────────────────────────────────┐
│  Roomy.app    │  │  roomy CLI  (macOS + Linux)       │
│  SwiftUI      │  │  scan · clean · purge · fleet …   │
└──────┬────────┘  └───────┬──────────────┬───────────┘
       │                   │              │
       │            ┌──────▼─────────┐    │
       │            │  RoomyFleet    │    │   policy, evaluator, audit log,
       │            │                │    │   Prometheus, HTTP server, license
       │            └──────┬─────────┘    │
       ▼                   ▼              ▼
┌──────────────────────────────────────────────────────┐
│  RoomyCore  (Foundation only)                        │
│  Models · RuleCatalog (JSON) · FilesystemArtifact-   │
│  Scanner · SystemArtifactScanner + probes · Disposal │
│  (Trash / freedesktop Trash / quarantine / delete) · │
│  ScanReport + CleanupPlan · Platform seams           │
└──────────────────────────────────────────────────────┘
```

## RoomyCore

- **Models** (`Models/`): `ScanArtifactFinding`, `ScanAggregate`, `ArtifactSafetyTier` (`safe < caution < warning`), `ArtifactSource`, `ProjectActivity`, `RoomyAppSettings` (pure data; persistence lives in each front-end).
- **Rule catalog** (`Rules/`): `builtin-rules.json` is embedded at build time. `RuleCatalog` decodes, validates, merges extra catalogs by rule id, removes disabled ids, and exposes the walk-skip list. See [rules.md](rules.md).
- **Scanning** (`Scan/`): `FilesystemArtifactScanner` walks a tree and matches folder names against project rules, disambiguating with marker files (`Cargo.toml`, `build.gradle`…). It never descends into a matched artifact or a walk-skip directory. `SystemArtifactScanner` runs the probes for enabled categories.
- **Probes** (`Probes/`): `CatalogPathProbe` turns catalog `systemRules` into findings (fixed paths, globs, `children` mode, file rules). Code-backed probes handle what data cannot: Docker and Conda CLIs, pip orphans, global npm/yarn modules, Electron app caches per app, VS Code agent extension storage, Claude Code per-project transcripts, Cursor stale agent builds (symlink check), Xcode archives and simulators, the Homebrew prefix cache. Each declares `supportedPlatforms`.
- **Disposal** (`Disposal/`): `RoomyDeletionService.dispose(paths:method:)`. `trash` is Finder Trash on macOS and the freedesktop spec on Linux (home volume: `$XDG_DATA_HOME/Trash`, other volumes: `<mount>/.Trash-<uid>`). `quarantine` moves to `~/.roomy/quarantine` (same volume → rename) with a sidecar manifest; `purge` removes expired items, `restore` moves them back. `delete` is permanent. `docker:`, `conda:` and `pip:` targets go through their tool.
- **Reports** (`Reports/`): `ScanReport` (what `roomy scan --json` prints) and `CleanupPlan` (what `roomy clean` consumes). Both carry `schemaVersion`; changes are additive.
- **Platform** (`Platform/`): `RoomyPlatform.current`, `RoomyPathResolver` (`~`, `$XDG_*`, `$VAR`), `ProcessRunner` (timeouts, concurrent pipe draining), `RoomyVolumeSpaceReader`, `RoomyHost`.

Only two places in the core are platform-conditional: `FileManager.trashItem` and the "available for important usage" volume key. Everything else differs only through catalog paths.

## RoomyFleet

- `FleetPolicy` — JSON, every field defaulted, validated on load. Profiles: `agentHostProfile`, `developerProfile`.
- `PolicyEvaluator` — pure: report + policy → `CleanupPlan` + skip reasons.
- `AuditLog` — JSON Lines, each record hashes the previous one (SHA-256). `verify` recomputes the chain.
- `PrometheusRenderer` / `MetricsServer` — text exposition, atomic textfile write, tiny POSIX HTTP server.
- `LicenseVerifier` — Ed25519 tokens, compiled-in public key, offline.
- `FleetRunner` — lock → scan → evaluate → dispose → purge → audit → metrics → report to hub.
- **Hub** (`Hub/`): `HubHostReport` (what a host posts), `HubStore` (JSON files per host, policies, event log; status and summary computation), `HTTPServer` (POSIX sockets, bounded bodies, one handler), `HubServer` (routes, two-token auth, license allowance, fleet metrics, embedded `dashboard.html`), `HTTPClient` (socket client for http, `curl` for https, so the static Linux binary needs no libcurl), `HubClient` (agent and operator calls), `HubDemo` (deterministic synthetic fleet).

## Front-ends

- **Roomy.app** keeps `UserDefaults` persistence (`RoomySettingsStore`, `ExclusionsStore`, `LastScanPersistence`), SwiftUI views, colors for tiers and activity. It depends on `RoomyCore` through a local package reference in the Xcode project.
- **roomy CLI** reads flags and JSON files, prints tables or JSON, and is the same binary logic on macOS and Linux. `roomy hub serve` is the same binary acting as the central service; the dashboard is one HTML file embedded in `RoomyFleet` at build time.

## Platform matrix

| Capability | macOS | Linux |
|---|---|---|
| Project walk, all project rules | ✓ | ✓ |
| AI tools, agent host, package caches, Docker, Conda, pyenv, global modules | ✓ | ✓ |
| Xcode, simulators, Homebrew | ✓ | — (nothing to find) |
| Trash | Finder | freedesktop |
| Quarantine | ✓ | ✓ (recommended on headless hosts) |
| Fleet | ✓ | ✓ |

## Conventions

- Core never imports SwiftUI, AppKit or ArgumentParser.
- New fixed-path targets go in `builtin-rules.json`, not in Swift.
- Anything that needs a display decision (colors, column widths) belongs in a front-end.
- JSON shapes that leave the process (`ScanReport`, `CleanupPlan`, `FleetPolicy`, `AuditRecord`) are additive-only.
