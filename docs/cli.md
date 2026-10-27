# `roomy` CLI reference

Same core as the Mac app, for terminals, scripts and agents. macOS (universal) and Linux (static binary).

```
roomy scan [paths…] [--json] [--plan FILE] …    find reclaimable artifacts (never deletes)
roomy clean --plan FILE [--dry-run] [--yes] …    remove exactly what the plan lists
roomy purge [--older-than DAYS] [--trash]        empty expired quarantine (and Linux Trash)
roomy restore [PATH]                             list or restore quarantined items
roomy rules [--json] [--platform P]              show the rule catalog
roomy doctor                                     environment check
roomy fleet …                                    policy-driven, unattended (see fleet.md)
roomy hub …                                      central inventory and dashboard (see hub.md)
roomy version [--json]
```

`roomy --help` and `roomy <command> --help` are authoritative.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK (including "nothing to do") |
| 1 | Error, or `clean` refused to proceed without confirmation |
| 3 | Finished, but some items failed to dispose |
| 4 | Another `fleet run` holds the lock |
| 5 | `clean` refused the plan because it contains items above the allowed safety tier |
| 64 | Usage error (bad flag or value) |

## `roomy scan`

```
roomy scan [<roots>…]
  --home DIR                 home to probe for tool caches (default: current user)
  --categories a b …         system categories: aiTools agentHost xcode globalCaches globalModules python homebrew docker
  --ecosystems a b …         ai npm py rust ruby go java swift dotnet general
  --exclude P …              paths or globs to skip
  --rules FILE …             extra rule catalogs merged over the built-in one
  --disable-rule ID …        switch rules off
  --no-system | --no-projects
  --json                     full ScanReport on stdout
  --plan FILE                write a CleanupPlan
  --plan-tier safe|caution|warning     highest tier admitted to the plan (default safe)
  --min-idle-days N          only plan items idle ≥ N days
  --require-known-idle       exclude items whose idle time is unknown
  --method trash|quarantine|delete     disposal recorded in the plan
  --top N                    table rows (default 40)
  -q, --quiet                no progress on stderr
```

Roots default to the home directory. The walk never enters tool-owned trees (see [rules.md](rules.md#walk-skip)) unless one is given as the root.

### ScanReport (`--json`, `schemaVersion: 1`)

```jsonc
{
  "schemaVersion": 1, "roomyVersion": "1.3.0", "catalogVersion": "2026.10.27",
  "generatedAt": "2026-10-27T00:00:00Z", "host": "agent-07", "platform": "linux",
  "scanRoot": "/home/agent", "home": "/home/agent", "durationSeconds": 1.2, "partial": false,
  "totalBytes": 1610612736,
  "bytesByTier": { "safe": 1500000000, "caution": 0, "warning": 1048576 },
  "bytesByCategory": { "project": 900000000, "aiTools": 600000000, "globalCaches": 110000000 },
  "bytesByEcosystem": { "py": 900000000, "ai": 600000000, "npm": 110000000 },
  "projectCount": 3,
  "volume": { "totalBytes": 1374000000000, "availableBytes": 1288000000000 },
  "items": [
    {
      "id": "9f1c…",                 // stable per path
      "path": "/home/agent/.cache/uv", "displayPath": "~/.cache/uv",
      "label": "uv cache", "bytes": 492000000,
      "tier": "safe", "ecosystem": "py", "category": "globalCaches",
      "group": "Global package caches", "source": "systemProbe", "ruleID": "uv-cache",
      "restoreHint": "uv cache clean",
      "lastActivity": "2026-10-20T10:00:00Z", "idleDays": 7, "activity": "recent"
    }
  ]
}
```

`category` is `project` for project-walk findings or the system category key. `source` is one of `projectWalk`, `systemProbe`, `dockerCLI`, `condaCLI`, `pipCLI`; the last three have synthetic `path`s (`docker:prune:dangling`, `conda:env:foo`, `pip:orphan:/path/.venv`).

## `roomy clean`

```
roomy clean --plan FILE
  --method M                 override the plan's method
  --allow-caution            admit review-tier items
  --allow-irreversible       admit irreversible items (session history, archives, volumes)
  --dry-run                  report, touch nothing
  -y, --yes                  skip confirmation (required when stdin is not a TTY)
  --json                     summary on stdout
  --audit FILE               audit log (default ~/.roomy/audit.jsonl)
  --quarantine-dir DIR       (quarantine) default ~/.roomy/quarantine or $ROOMY_QUARANTINE_DIR
  --retention-days N         recorded for purge (default 7)
  --actor NAME               recorded in the audit log, e.g. "claude-code"
```

Rules of engagement:

1. Only paths in the plan are touched. Items that no longer exist are skipped and reported.
2. Tier is enforced at clean time, not plan time: a plan containing a `warning` item is refused with exit 5 unless `--allow-irreversible` is passed, even if the plan was written with `--plan-tier warning`.
3. Without a TTY, `--yes` is mandatory. Agents should pass `--yes` only after inspecting the plan.
4. Every receipt and failure is appended to the audit log.

### CleanupPlan (`schemaVersion: 1`)

```jsonc
{
  "schemaVersion": 1, "createdAt": "…", "host": "…", "method": "quarantine", "reason": "roomy scan --plan",
  "items": [ { "id": "…", "path": "…", "label": "…", "bytes": 1, "tier": "safe", "category": "project", "source": "projectWalk", "ruleID": "node_modules" } ]
}
```

Any tool may write a plan: filter a `ScanReport`'s `items` and keep the fields above.

## `roomy purge` / `roomy restore`

Quarantine keeps a `<timestamp>-<name>.roomy.json` manifest next to each item with the original path, size and time. `purge --older-than N` removes expired items permanently; `--trash` also purges the freedesktop Trash on Linux. `restore <path-suffix>` moves an item back; with no argument it lists the quarantine.

## `roomy rules`

Prints project rules and system rules for a platform, or the whole catalog as JSON. The JSON is the same schema accepted by `--rules FILE` and a policy's `scan.extraRules`.

## `roomy doctor`

Checks `du`, `git`, `docker`, `conda`, Trash support, the quarantine directory, volume capacity and the license in effect. Nothing is modified except creating the quarantine directory.

## Environment variables

| Variable | Effect |
|---|---|
| `ROOMY_POLICY` | default policy path for `roomy fleet` |
| `ROOMY_HUB_URL`, `ROOMY_HUB_TOKEN` | defaults for `roomy hub status/hosts/…` (and the agent token for a host, when the policy has none) |
| `ROOMY_HUB_DATA`, `ROOMY_HUB_AGENT_TOKEN`, `ROOMY_HUB_ADMIN_TOKEN` | defaults for `roomy hub serve` |
| `ROOMY_LICENSE` | license token (alternative to a key file) |
| `ROOMY_QUARANTINE_DIR` | default quarantine directory |
| `ROOMY_HOSTNAME` | host label in reports, audit and metrics |
| `XDG_DATA_HOME` | where the freedesktop Trash lives on Linux |

## `roomy hub`

```
roomy hub serve [--listen H:P] [--data-dir DIR] [--agent-token T|--agent-token-file F] [--admin-token T|--admin-token-file F] [--stale-after 24h] [--license TOKEN] [--title NAME]
roomy hub status | hosts [--status S] | host NAME [--note TEXT] | remove NAME | events [-n N]     (--url, --token, --json)
roomy hub policy list | get NAME | push NAME FILE | remove NAME
roomy hub demo [--data-dir DIR] [--hosts N] [--seed N] [--org NAME] [--reset]
roomy hub token
```

Reference: [hub.md](hub.md).
