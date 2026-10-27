# Agent notes for this repository

## Freeing disk space with Roomy (any agent)

Roomy is installed as `roomy`. It never deletes without a plan file.

```sh
roomy scan --json --quiet                       # report: bytesByTier, items[] with tier/category/bytes/idleDays
roomy scan --plan /tmp/plan.json --quiet        # plan = safe-tier items only
roomy clean --plan /tmp/plan.json --dry-run --json
roomy clean --plan /tmp/plan.json --yes --json --actor "<your-agent-name>"
```

- `tier: safe` is regenerable. `caution` needs `--allow-caution` and user approval. `warning` is irreversible (session history, archives, volumes): never automate it.
- Disposal is Trash on macOS, quarantine on Linux. `roomy restore <path>` undoes; `roomy purge` frees quarantine after the retention period.
- Exit 5 means the plan contained items above the allowed tier. Exit 3 means some items failed. Exit 0 with "nothing to do" is fine.

See `docs/agents.md`.

## Working on this codebase

- Core logic lives in `RoomyCore/` (Swift package). The Mac app (`Roomy/`, in the private repository) is a front-end; do not add scanning or deletion logic there.
- New fixed-path targets are rules in `RoomyCore/Sources/RoomyCore/Rules/builtin-rules.json`, not Swift.
- Run `cd RoomyCore && swift test` before and after changes; `xcodebuild -project Roomy.xcodeproj -scheme Roomy build` for the app.
- JSON shapes that leave the process (`ScanReport`, `CleanupPlan`, `FleetPolicy`, `AuditRecord`, `HubHostReport`, `HubSummary`) are additive-only.
- The hub dashboard is `RoomyCore/Sources/RoomyFleet/Hub/dashboard.html`, embedded at build time; it must stay a single file with no external assets.
