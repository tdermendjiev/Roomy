# Roomy Fleet

Unattended, policy-driven cleanup for machines nobody is watching: agent hosts, CI runners, shared dev boxes. The policy says what may be removed without a human; everything else is reported, never touched.

```
roomy fleet policy init --profile agent-host --output /etc/roomy/policy.json
roomy fleet policy check            # scan, show what the policy would remove; disposes of nothing
roomy fleet run                     # one run: lock → scan → evaluate → dispose → purge → audit → metrics
roomy fleet serve --interval 6h     # run on a schedule and serve /metrics, /healthz, /report
roomy fleet audit verify|tail       # tamper-evident log
roomy fleet license show|install    # edition in effect
roomy fleet metrics                 # print the Prometheus text a run would produce
roomy hub …                         # central inventory and dashboard (see hub.md)
```

Policy resolution order: `--policy FILE`, `$ROOMY_POLICY`, `/etc/roomy/policy.json`, `~/.roomy/policy.json`.

## A run, step by step

1. **Lock** `~/.roomy/fleet.lock` (pid; stale locks are reclaimed). A concurrent run exits 4.
2. **Scan** the policy's roots and categories with the effective catalog (built-in + `extraRules` − `disabledRules`).
3. **Evaluate**: each finding is either selected or skipped with a reason (`tierNeverRemoved`, `tierNotAutoCleaned`, `ruleNeverRemoved`, `pathProtected`, `categoryNotAllowed`, `ecosystemNotAllowed`, `tooRecent`, `idleUnknown`, `tooSmall`, `overBudget`). Largest first, so a byte budget buys the most space.
4. **Dispose** selected items with the policy's method. Default is **quarantine**: a rename into `~/.roomy/quarantine` on the same volume with a manifest, so the run is instant and reversible.
5. **Purge** quarantine items older than `retentionDays` (and, on Linux with `method: trash`, the freedesktop Trash). This is when space is actually freed.
6. **Audit**: every step above is one JSON line with the hash of the previous line.
7. **Metrics**: written atomically to the node_exporter textfile path, and served by `fleet serve`.
8. **Report to the hub**, when the policy sets `hub.url`: a few-KB summary of steps 2–7 plus the audit chain head. Failure is logged and audited, never fatal. See [hub.md](hub.md).

`--dry-run` (or `"dryRun": true`) does 1–3 and 6–7, and logs what 4 would have done.

## systemd

Packages install three units; the instance name is the Unix user whose home is cleaned.

```sh
sudo systemctl enable --now roomy-fleet@agent.timer         # oneshot every 6h, randomized ±15min
sudo systemctl enable --now roomy-fleet-serve@agent.service # long-running, serves metrics on 127.0.0.1:9477
journalctl -u roomy-fleet@agent.service
```

Run Roomy as the user who owns the files. Running as root to clean many homes works (`scan.home` per policy, one unit instance per user) but is rarely needed.

## Prometheus

**Textfile collector** (default): the policy's `metrics.textfile` points into node_exporter's `--collector.textfile.directory`. No extra port, no extra process.

**Built-in server** (`roomy fleet serve`, or `metrics.listen`): `GET /metrics` (text exposition), `GET /healthz` (200 when the last run had no failures), `GET /report` (last ScanReport as JSON).

| Metric | Type | Labels |
|---|---|---|
| `roomy_build_info` | gauge (1) | version, catalog, edition, org |
| `roomy_reclaimable_bytes` | gauge | tier |
| `roomy_reclaimable_bytes_by_category` | gauge | category |
| `roomy_reclaimable_items`, `roomy_planned_bytes`, `roomy_planned_items` | gauge | |
| `roomy_last_run_disposed_bytes`, `roomy_last_run_failures` | gauge | |
| `roomy_disposed_bytes_total`, `roomy_disposed_items_total`, `roomy_dispose_failures_total`, `roomy_purged_bytes_total`, `roomy_runs_total` | counter (from the audit log, monotonic across restarts) | |
| `roomy_last_run_timestamp_seconds`, `roomy_last_run_duration_seconds`, `roomy_last_run_success`, `roomy_dry_run` | gauge | |
| `roomy_quarantine_bytes`, `roomy_quarantine_items` | gauge | |
| `roomy_volume_total_bytes`, `roomy_volume_available_bytes` | gauge | |
| `roomy_license_expiry_timestamp_seconds` | gauge | |

Every series carries `host` and `policy`. Useful alerts: `roomy_volume_available_bytes / roomy_volume_total_bytes < 0.1`, `time() - roomy_last_run_timestamp_seconds > 2 * interval`, `increase(roomy_dispose_failures_total[1d]) > 0`, `roomy_reclaimable_bytes{tier="safe"} > 50e9` (policy is too conservative).

## Audit log

`~/.roomy/audit.jsonl` by default (`audit.path`). One JSON object per line:

```json
{"seq":42,"time":"2026-10-27T01:00:00Z","host":"agent-07","runID":"…","event":"disposed","actor":"roomy-fleet","edition":"fleet","policy":"agent-host","path":"/home/agent/.cache/uv","bytes":492000000,"tier":"safe","category":"globalCaches","ruleID":"uv-cache","method":"quarantine","destination":"/home/agent/.roomy/quarantine/20261027T010000-uv","prevHash":"…","hash":"…"}
```

Events: `runStarted`, `licenseChecked`, `scanCompleted`, `planned`, `skipped`, `disposed`, `disposeFailed`, `purged`, `runFinished`, `hubReported`, `error`. `hash = SHA256(prevHash ‖ record-without-hash)`; `roomy fleet audit verify` recomputes the chain and exits 1 on any edit or gap. Ship the file to your SIEM as-is; it is plain JSON Lines. `roomy clean` appends to the same log with `actor` set from `--actor`. Records written by a dry run carry `dryRun: true`; their `disposed` events describe what would have been removed and are not counted in totals, metrics or the hub.

## Licensing

Without a license every fleet command works in **community** edition; metrics and audit records say so. A **fleet** license (offline Ed25519 token) sets the edition, records the organisation and host allowance, and is what commercial support is attached to. See [licensing.md](licensing.md).

## Many hosts

Per-host metrics and audit logs scale as far as your Prometheus and log pipeline do. For an inventory, fleet totals, a dashboard and one place to push policies from, run [Roomy Hub](hub.md) and point hosts at it with `hub.url`.

## Rollout advice

1. Start with `dryRun: true` for a week. Read `roomy fleet policy check` and the `skipped` reasons; tune `minIdleDays`, `never.paths`, `disabledRules`.
2. Switch to `quarantine` with `retentionDays: 7`. Watch `roomy_quarantine_bytes`; space is reclaimed on purge.
3. Only then consider `method: delete` for throwaway hosts, or adding `caution` to `autoClean.tiers` for specific categories.
