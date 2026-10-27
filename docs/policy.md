# Policy file reference

JSON. Every field is optional; defaults are shown. Validate with `roomy fleet policy check`. Print the effective policy with `roomy fleet policy show`.

```jsonc
{
  "schemaVersion": 1,
  "name": "default",                      // appears in audit records and metrics labels

  "scan": {
    "roots": ["~"],                       // directories to walk for project artifacts; [] = no walk
    "home": null,                         // home to probe for tool caches; null = current user
    "categories": null,                   // null = all available on this platform; else a list of category keys
    "ecosystems": null,                   // null = all
    "exclude": [],                        // paths or globs never scanned
    "extraRules": [],                     // extra catalog files, merged by rule id
    "disabledRules": []                   // rule ids switched off
  },

  "autoClean": {
    "tiers": ["safe"],                    // tiers removable without a human
    "categories": null,                   // restrict to categories (null = any); "project" is the project walk
    "ecosystems": null,
    "minIdleDays": 7,                     // 0 = no age requirement
    "requireKnownIdle": false,            // true = skip items whose idle time is unknown
    "minBytes": 1048576,
    "maxBytesPerRun": null,               // stop selecting past this many bytes (largest first)
    "maxItemsPerRun": null
  },

  "never": {
    "tiers": ["warning"],                 // never removed by policy, regardless of autoClean
    "ruleIDs": [],                        // e.g. ["cursor-state-backup"]
    "paths": []                           // prefixes or globs, e.g. ["~/.claude/projects", "*/important/*"]
  },

  "disposal": {
    "method": "quarantine",               // trash | quarantine | delete
    "quarantineDir": null,                // default ~/.roomy/quarantine (or $ROOMY_QUARANTINE_DIR)
    "retentionDays": 7,
    "purgeOnRun": true                    // purge expired quarantine (and Linux trash) at the end of a run
  },

  "audit":   { "path": null },            // default ~/.roomy/audit.jsonl
  "metrics": { "textfile": null,          // e.g. /var/lib/node_exporter/textfile_collector/roomy.prom
               "listen": null },          // host:port for `fleet serve`; default 127.0.0.1:9477
  "license": { "key": null, "keyFile": null },   // also $ROOMY_LICENSE, /etc/roomy/license.key, ~/.roomy/license.key

  "lockFile": null,                       // default ~/.roomy/fleet.lock
  "hub": {
    "url": null,                          // "http://hub.internal:9478" → report to a Roomy Hub after every run
    "token": null, "tokenFile": null,     // agent token; also /etc/roomy/hub.token, ~/.roomy/hub.token, $ROOMY_HUB_TOKEN
    "policy": null,                       // name of a hub-managed policy to pull before each run
    "tags": {},                           // labels for the dashboard: role, team, region…
    "topItems": 25,                       // largest findings included in the report (0–200)
    "intervalSeconds": null               // expected run cadence for staleness; set by `fleet serve`
  },

  "dryRun": false,
  "dormantMonths": 24, "inactiveMonths": 6   // activity labels in reports
}
```

Validation rejects: a tier in both `autoClean.tiers` and `never.tiers`; unknown categories or ecosystems; negative retention or idle days; a `hub.url` that is not http(s); a schema version newer than the binary supports.

When `hub.policy` is set, the policy actually run is the hub-managed one; the local file contributes only `hub`, `license`, `scan.home` and `lockFile` (see [hub.md](hub.md)).

## Profiles

`roomy fleet policy init --profile agent-host` — no project walk beyond `~`, tool caches and leftovers only, safe tier idle ≥ 3 days, quarantine 7 days, metrics to node_exporter, Claude and Codex session dirs protected.

`roomy fleet policy init --profile developer` — walk `~`, safe tier idle ≥ 30 days with known idle only, Trash, no automatic purge.

Add `--hub URL [--hub-policy NAME] [--tag key=value …]` to either profile to fill in the `hub` section.

## Examples

Aggressive, for disposable CI runners:
```json
{ "name": "ci-runner", "scan": { "roots": ["/home/runner/work", "~"] },
  "autoClean": { "tiers": ["safe", "caution"], "minIdleDays": 0 },
  "disposal": { "method": "delete" } }
```

Conservative, models only:
```json
{ "name": "models-only", "scan": { "roots": [], "categories": ["aiTools"] },
  "autoClean": { "tiers": ["safe"], "ecosystems": ["ai"], "minIdleDays": 14, "maxBytesPerRun": 50000000000 } }
```
