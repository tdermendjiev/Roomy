# Rule catalog

The catalog is data: `RoomyCore/Sources/RoomyCore/Rules/builtin-rules.json`, embedded into every binary at build time. `roomy rules --json` prints the effective catalog. Extra catalogs are merged at runtime (`roomy scan --rules FILE`, policy `scan.extraRules`), and rules can be switched off by id (`--disable-rule`, policy `scan.disabledRules`), so a fleet can add a new agent's cache directory without waiting for a release.

```jsonc
{
  "schemaVersion": 1,
  "catalogVersion": "2026.10.27",
  "projectRules": [ … ],
  "systemRules": [ … ],
  "walkSkip": { "all": [ … ], "macos": [ … ], "linux": [ … ] }
}
```

## Safety tiers

| Tier | Meaning | App | CLI `clean` | Fleet policy |
|---|---|---|---|---|
| `safe` | Fully regenerable | bulk-selectable | default | default `autoClean.tiers` |
| `caution` | Regenerable at a cost, or mixed with user data | shown as *Review* | `--allow-caution` | opt in |
| `warning` | Not regenerable | *Irreversible*, never bulk-selected | `--allow-irreversible` | always in `never.tiers` by default |

When in doubt, classify up. A wrong `safe` loses someone's data; a wrong `warning` costs a click.

## Project rules

Matched by folder name while walking project trees. The walk does not descend into a matched folder.

```jsonc
{
  "id": "target",                 // unique across the catalog
  "folderName": "target",         // last path component to match
  "parentName": ".claude",        // optional: only match when the parent folder has this name
  "label": "target/",
  "ecosystem": "general",         // used when no marker matches
  "tier": "safe",
  "restoreHint": "cargo build / mvn package",
  "markers": [                    // optional: first marker whose file exists next to the folder wins
    { "ecosystem": "rust", "files": ["Cargo.toml"] },
    { "ecosystem": "java", "files": ["pom.xml", "build.gradle", "build.gradle.kts"] }
  ],
  "requireMarker": false,         // true → ignore the folder unless a marker matches (ambiguous names like `obj`)
  "platforms": ["macos"]          // optional; empty = all
}
```

Marker `files` may be globs (`*.csproj`).

## System rules

Fixed locations owned by a tool, with per-platform paths.

```jsonc
{
  "id": "cursor-state-backup",
  "category": "aiTools",          // aiTools agentHost xcode globalCaches globalModules python homebrew docker
  "label": "Cursor state database backup",
  "ecosystem": "ai",
  "tier": "caution",
  "restoreHint": "Cursor rewrites the backup from the live database",
  "kind": "file",                 // directory (default) | file
  "mode": "directory",            // directory (default): the path is one finding | children: each child dir is a finding
  "activity": "none",             // none | self (mtime of the item) | newestChild (newest of item + direct children)
  "childLabel": "pyenv {name}",   // optional template for children/glob matches: {name}, {parent}
  "paths": {
    "macos": ["Library/Application Support/Cursor/User/globalStorage/state.vscdb.backup"],
    "linux": [".config/Cursor/User/globalStorage/state.vscdb.backup"]
  }
}
```

Path specs: home-relative by default; `~/…` or absolute; `$VAR` and `${VAR}` expand from the environment with XDG defaults (`$XDG_CACHE_HOME` → `~/.cache`, `$TMPDIR` → `/tmp`); a glob (`*`, `?`, `[…]`) is allowed in any component (`/tmp/claude-*`, `Library/Application Support/*/Crashpad/pending`). A spec with an unresolvable variable is skipped. Findings under 1 MB are dropped.

Anything that needs a CLI call or a symlink check stays in Swift: see `Sources/RoomyCore/Probes/`.

## Walk skip

Directories the project walk never enters, because a `node_modules` or `dist` inside them is part of a tool's install, not a project artifact: `~/.cursor-server`, `~/.vscode-server`, `~/.nvm`, `~/.pyenv`, `~/.cargo`, `~/.gradle`, `~/Library` (macOS), `~/.config/Cursor` (Linux), `/proc`, `/usr`, … plus `.git`. The system probes cover the ones worth reclaiming. A skipped directory is still scanned when it is given explicitly as the root.

Bare names (`.git`) match any folder with that name; everything else resolves against the home directory.

## Adding a rule

1. Measure first: find the path on a real machine, check what regenerates it, decide the tier.
2. Add to `builtin-rules.json` with both platform paths when they exist.
3. `cd RoomyCore && swift test` — `RuleCatalogTests` validates ids, categories and platforms.
4. For a probe that needs logic, add a `SystemArtifactProbe` in `Probes/`, register it in `SystemArtifactScanner.buildProbes`, and give findings a `ruleID` so policies can reference it.

## Custom catalogs

A file with the same schema. Only the fields you set are needed; `id` is required. Rules with an existing id replace the built-in rule; new ids are appended; `walkSkip` lists are concatenated.

```sh
roomy scan --rules /etc/roomy/rules.d/our-agent.json
roomy rules --rules /etc/roomy/rules.d/our-agent.json --category agentHost
```
