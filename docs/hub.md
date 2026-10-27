# Roomy Hub

The central view of a fleet. Every host running `roomy fleet` posts a short report after each run; the hub keeps an inventory, a history per host, fleet-wide totals and metrics, and serves a dashboard. It also hands out centrally managed policies.

```
roomy hub serve --listen 0.0.0.0:9478 --data-dir /var/lib/roomy-hub \
                --agent-token-file /etc/roomy/hub.agent.token --admin-token-file /etc/roomy/hub.admin.token
roomy hub status | hosts | host NAME | remove NAME | events      # talk to a hub (--url, --token)
roomy hub policy list | get NAME | push NAME FILE | remove NAME  # centrally managed policies
roomy hub demo --data-dir ~/.roomy/hub-demo --hosts 12            # synthetic fleet to try the dashboard
roomy hub token                                                   # random token for the two files above
```

One static binary, no database, no TLS of its own: put it on a private network or behind your reverse proxy, like node_exporter or Prometheus itself. Hosts and the `roomy hub` CLI talk plain HTTP with a built-in client; an `https://` hub URL is handled by the system `curl`, so TLS to a reverse proxy works without Roomy linking a TLS stack.

## How a host reports

In the host's policy:

```json
{ "hub": { "url": "http://hub.internal:9478", "tokenFile": "/etc/roomy/hub.token",
           "tags": { "role": "agent", "team": "platform" }, "policy": "agent-host" } }
```

or `roomy fleet policy init --profile agent-host --hub http://hub.internal:9478 --hub-policy agent-host --tag role=agent`.

After every `roomy fleet run` (and every cycle of `fleet serve`) the host posts a `HubHostReport`: host, platform, Roomy and catalog version, policy name, edition, tags, what the scan found by tier and category, what the policy selected, what was removed, cumulative totals from the audit log, quarantine size, disk space, the audit chain head (`seq` + hash), and the largest findings (`hub.topItems`, default 25, warning tier included so the dashboard can show what the policy is *not* allowed to remove). A few kilobytes. The audit log records `hubReported`, or `error` with the reason if the hub was unreachable. **A hub outage never stops a run.**

`fleet serve` reports its interval so the hub can tell a quiet host from a dead one; timer-driven hosts set `hub.intervalSeconds` or inherit the hub's `--stale-after` (default 24h).

## Centrally managed policies

`roomy hub policy push ci-runner policy.json` validates and stores a policy on the hub. A host whose local policy sets `hub.policy: "ci-runner"` fetches it before every run and uses it instead of the local file, keeping only the local `hub`, `license`, `scan.home` and `lockFile` sections. If the hub cannot be reached the host runs its local policy and says so in the log. `--local-policy` on `fleet run`/`serve` skips the pull.

So the local file on each host can be a two-line bootstrap, and a policy change is one push plus the next run.

## Host status

| Status | Meaning |
|---|---|
| **healthy** | reported within the window, last run had no failures, disk above 10% free |
| **attention** | reported, but: disposal failures in the last run, under 10% free, over the license allowance, or an expired fleet license |
| **stale** | no report for 2.5× the host's interval (minimum 15 minutes), or `--stale-after` when the interval is unknown |

Hosts that are over the license allowance still appear with their reports; only *new* hosts beyond it are refused with HTTP 402 and an event. Removing a host (`roomy hub remove`, or the dashboard) drops it from the inventory; it comes back on its next report.

## Dashboard

`GET /` is a single self-contained page, no external assets, works air-gapped.

- **Overview**: hosts by status, reclaimable by tier, freed in the last 24h / 7d / all-time, hosts under disk pressure, quarantine held; freed per day for 14 days; reclaimable by category; the hosts with the most to reclaim, by tier; the largest findings across the fleet; hosts that need attention; recent runs.
- **Hosts**: searchable, filterable, sortable inventory with tags, status reasons, tier bars, disk meter, a reclaimable sparkline and last-report age.
- **Host**: everything in the last report, reclaimable over time, freed per run, the largest findings with tier and idle time, why items were skipped, audit chain head, an operator note, and removal.
- **Policies**: hub-managed policies and which hosts use each policy name.
- **Activity**: the hub's own event log (reports, rejections, policy pushes, removals).

With `--admin-token` set, the page asks for the token once and keeps it in the browser's local storage.

## API

All JSON. `Authorization: Bearer <token>` (or `?token=`). *Agent* routes accept the agent or admin token; everything else needs the admin token. Without any token configured the API is open, which is fine on `127.0.0.1` and a warning anywhere else.

| Route | Who | What |
|---|---|---|
| `POST /api/v1/report` | agent | ingest a `HubHostReport`; `402` when a new host exceeds the allowance |
| `GET /api/v1/policies`, `GET /api/v1/policies/{name}` | agent | list / fetch a managed policy |
| `PUT /api/v1/policies/{name}` (body: policy JSON), `DELETE …` | admin | store (validated) / remove |
| `GET /api/v1/summary` | admin | the `HubSummary` the overview is drawn from |
| `GET /api/v1/hosts` | admin | inventory rows with status (history trimmed, top items omitted) |
| `GET /api/v1/hosts/{name}`, `DELETE …`, `PUT …/note` (text body) | admin | one host in full / remove / note |
| `GET /api/v1/events?n=50` | admin | recent hub events |
| `GET /api/v1/license` | admin | edition, org, allowance, hosts over it |
| `GET /api/v1/info` | public | name, version, whether auth is required |
| `GET /metrics` | admin | fleet-wide Prometheus text |
| `GET /healthz` | public | `ok` |

Shapes (`HubHostReport`, `HubSummary`, `HubHostRecord`, `HubEvent`) are versioned by `schemaVersion` and additive-only, like `ScanReport`.

## Metrics

Scrape `/metrics` with the admin token (`authorization: credentials` in the Prometheus job). Fleet series: `roomy_hub_hosts{status}`, `roomy_hub_license_hosts_max`, `roomy_hub_reclaimable_bytes{tier}`, `roomy_hub_reclaimable_bytes_by_category{category}`, `roomy_hub_disposed_bytes_total`, `roomy_hub_disposed_bytes_last_24h`, `roomy_hub_dispose_failures_total`, `roomy_hub_quarantine_bytes`, `roomy_hub_volume_available_bytes`, `roomy_hub_volume_total_bytes`, `roomy_hub_hosts_low_disk`. Per-host series carry `host`: `roomy_hub_host_info{platform,version,policy,edition,status}`, `roomy_hub_host_reclaimable_bytes{tier}`, `roomy_hub_host_disposed_bytes_total`, `roomy_hub_host_last_run_disposed_bytes`, `roomy_hub_host_last_run_failures`, `roomy_hub_host_last_run_success`, `roomy_hub_host_dry_run`, `roomy_hub_host_last_report_timestamp_seconds`, `roomy_hub_host_quarantine_bytes`, `roomy_hub_host_volume_available_bytes`, `roomy_hub_host_volume_total_bytes`, `roomy_hub_host_audit_seq`.

Alerts worth having: `roomy_hub_hosts{status="stale"} > 0`, `roomy_hub_host_volume_available_bytes / roomy_hub_host_volume_total_bytes < 0.1`, `increase(roomy_hub_dispose_failures_total[1d]) > 0`, `roomy_hub_host_audit_seq` decreasing (a host's audit log was reset).

## Data directory

```
/var/lib/roomy-hub/
  hosts/<host>.json      latest report + up to 1000 history points + note
  policies/<name>.json   managed policies, exactly as pushed
  events.jsonl           hub event log
```

Plain files: back up with rsync, inspect with `jq`, delete a host file to forget it. The hub reloads everything on start.

## Running it

- **systemd** (from the packages): `roomy-hub.service` with `DynamicUser`, state in `/var/lib/roomy-hub`, settings in `/etc/roomy/hub.env`, tokens in `/etc/roomy/hub.agent.token` and `/etc/roomy/hub.admin.token` (`roomy hub token` makes one).
- **Docker**: `docker run -p 9478:9478 -v roomy-hub:/data ghcr.io/tdermendjiev/roomy hub serve --listen 0.0.0.0:9478 --data-dir /data --agent-token … --admin-token …`.
- **A laptop**: `roomy hub serve` listens on `127.0.0.1:9478` with no tokens; good for a first look with `roomy hub demo`.

## Editions

Without a license the hub tracks up to 5 hosts, enough to try it with real machines. A fleet license sets the allowance to its `maxHosts` and shows the organisation in the header. See [licensing.md](licensing.md).
