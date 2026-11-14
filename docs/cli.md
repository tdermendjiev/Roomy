# `roomy` CLI reference

Same core as the Mac app, for terminals, scripts and agents. macOS (universal) and Linux (static binary).

```
roomy scan [paths…] [--json] [--plan FILE] …    find reclaimable artifacts (never deletes)
roomy growth [--since 7d] [--json] …             what grew between two snapshots (never deletes)
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
  --snapshot                 also save a snapshot of this scan for `roomy growth`
  --snapshot-dir DIR         where snapshots live (default ~/.roomy/snapshots)
  --dirs                     with --snapshot: also record directory sizes under the home directory
  --dirs-root DIR …          with --snapshot: size these directories instead (implies --dirs)
  --dirs-depth N             with --dirs: levels below each root that get their own entry (default 2)
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

## `roomy growth`

Answers "what is filling the disk?". `roomy scan --snapshot` saves a compact copy of the scan (every finding with its size, plus free space); `roomy growth` compares two snapshots.

```
roomy growth
  --since 12h|7d|4w          compare against the snapshot closest to this long before the newest one
  --from FILE  --to FILE     compare two snapshot files directly
  --snapshot-dir DIR         where snapshots live (default ~/.roomy/snapshots)
  --min-delta-mb N           ignore changes smaller than N MB (default 1)
  --top N                    rows per table (default 15)
  --list                     list the snapshots instead of comparing
  --json                     full GrowthReport on stdout
```

Without `--since`, the two most recent snapshots are compared. With fewer than two snapshots it exits 64 and says so.

```
roomy growth · agent-07 · 2026-11-08 09:00 → 2026-11-15 09:00 (7.0 days)
Disk: 120.0 GB free → 95.0 GB free (used +25.0 GB)
Roomy targets: 40.0 GB → 52.0 GB (+12.0 GB)
Outside Roomy targets: +13.0 GB.

Grew (2)
CHANGE    NOW      STATUS  CATEGORY      PATH              LABEL
+9.0 GB   21.0 GB  grew    globalCaches  ~/.cache/uv       uv cache
+3.0 GB   3.0 GB   new     aiTools       ~/.ollama/models  Ollama models

Directories that grew · OUTSIDE is the part that is not a Roomy target
CHANGE    NOW      OUTSIDE   PATH
+13.0 GB  48.0 GB  +13.0 GB  ~/recordings
+9.0 GB   30.0 GB  0         ~/.cache
+9.0 GB   21.0 GB  0           ~/.cache/uv
```

**What it sees.** Findings are whatever Roomy's rules and probes match, compared by path: `grew`, `shrank`, `new`, or `gone` (removed, cleaned, or no longer matched). Growth outside the rules shows up only as the "Outside Roomy targets" figure, unless the snapshots were taken with `--dirs`. Then every directory down to `--dirs-depth` below the home directory (or the `--dirs-root` directories) is sized too, and the report lists the directories that grew and how much of that growth is not a Roomy target. `--dirs` reads the whole tree, so it is slower than a plain scan; it does not follow symlinks or enter other filesystems mounted below a root, and leaves out directories under 1 MB.

**Scheduling.** Snapshots are only useful on a schedule. Scan the same roots with the same flags each time, or the comparison is skewed (the report warns when the scan root differs).

```sh
# Linux, from the package: daily, as the user whose home is scanned
sudo systemctl enable --now roomy-snapshot@agent.timer

# anywhere, with cron: hourly
0 * * * *  roomy scan --snapshot --dirs --quiet >/dev/null
```

On macOS, a LaunchAgent in `~/Library/LaunchAgents/dev.getroomy.snapshot.plist` with `ProgramArguments` = `roomy scan --snapshot --dirs --quiet` and `StartCalendarInterval` = `{Hour: 9, Minute: 0}` does the same.

**Retention.** Each `--snapshot` run thins the directory: every snapshot from the last 14 days is kept, then one per calendar week, and anything older than a year is removed. Hourly snapshots therefore stay at a few hundred files.

### GrowthReport (`--json`, `schemaVersion: 1`)

```jsonc
{
  "schemaVersion": 1, "host": "agent-07", "home": "/home/agent",
  "from": "2026-11-08T09:00:00Z", "to": "2026-11-15T09:00:00Z", "seconds": 604800,
  "warnings": [],
  "volume": { "totalBytes": 500000000000, "fromAvailableBytes": 128849018880, "toAvailableBytes": 102005473280, "usedDeltaBytes": 26843545600 },
  "reclaimable": { "fromBytes": 42949672960, "toBytes": 55834574848, "deltaBytes": 12884901888 },
  "untrackedDeltaBytes": 13958643712,          // used-space growth the findings do not account for
  "minDeltaBytes": 1048576,
  "categories": [ { "category": "globalCaches", "fromBytes": 0, "toBytes": 0, "deltaBytes": 0 } ],
  "items": [                                   // largest growth first, largest shrinkage last
    { "path": "/home/agent/.cache/uv", "label": "uv cache", "category": "globalCaches", "tier": "safe", "ruleID": "uv-cache",
      "status": "grew", "fromBytes": 12884901888, "toBytes": 22548578304, "deltaBytes": 9663676416 }
  ],
  "dirs": [                                    // only when both snapshots were taken with --dirs
    { "path": "/home/agent/recordings", "depth": 1, "status": "grew", "fromBytes": 0, "toBytes": 0, "deltaBytes": 0,
      "reclaimableDeltaBytes": 0 }             // the part of deltaBytes that comes from findings inside it
  ]
}
```

A parent directory's growth includes its children's, so do not sum `dirs`. Snapshot files themselves are JSON with the same `schemaVersion`; both shapes are additive-only.

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
| `ROOMY_SNAPSHOT_DIR` | default snapshot directory for `scan --snapshot` and `growth` |
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
