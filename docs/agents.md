# Roomy for AI agents

An agent that hits `ENOSPC` mid-task, or is asked to free space, needs a tool it can call that is **structured, dry-run first, and incapable of deleting anything outside an explicit plan**. That is what the CLI is for.

## The contract

1. **Scan** produces data. `roomy scan --json` never deletes. Every item has a stable `id`, a `tier`, a `category`, `bytes`, `idleDays` and a `restoreHint`.
2. **Plan** is a file. Either `roomy scan --plan plan.json` (safe tier, by default) or a plan the agent writes by filtering the report's `items`.
3. **Clean** executes the plan and nothing else. Review-tier items need `--allow-caution`; irreversible items need `--allow-irreversible`. An agent should not pass the latter without a human in the loop.
4. **Disposal** defaults to Trash (macOS) or quarantine (Linux), so a mistake is recoverable for the retention period. `roomy restore` undoes.
5. **Audit**. Every removal is appended to `~/.roomy/audit.jsonl` with the `--actor` name. Pass your tool name.

## Recommended sequence

```sh
roomy doctor --json                                   # optional: is roomy usable here?
roomy scan --json --quiet > /tmp/roomy-report.json    # inspect bytesByTier, items
roomy scan --plan /tmp/roomy-plan.json --min-idle-days 7 --quiet
roomy clean --plan /tmp/roomy-plan.json --dry-run --json       # show the human (or your log) what will happen
roomy clean --plan /tmp/roomy-plan.json --yes --json --actor "claude-code"
```

Read `bytesByTier.safe` first: if it is already enough, stop there. Only escalate to `caution` with explicit user approval, and never automate `warning`.

## Writing your own plan

Filter the report and keep these fields per item: `id, path, label, bytes, tier, category, source, ruleID`. Wrap in `{ "schemaVersion": 1, "createdAt": ISO8601, "host": "…", "method": "quarantine", "reason": "agent:<name>", "items": [...] }`. `roomy clean` validates existence and tier at run time, so a stale or over-eager plan fails closed.

## What agents should know about the categories

- `project` — artifacts inside repositories (`node_modules`, `.venv`, `target/`). Safe. Regenerate with the install command in `restoreHint`.
- `aiTools` — the agents' own storage. Models and caches are safe; **session history is irreversible** (Claude Code projects, Codex sessions, Cline tasks, Cursor's `state.vscdb`).
- `agentHost` — leftovers on servers: OpenClaw build captures, crash dumps, Claude Code scratch dirs, stale Cursor agent builds, un-emptied Trash.
- `globalCaches`, `python`, `docker`, `globalModules`, `xcode`, `homebrew` — tool caches outside repositories.

## Packaging this as a skill

The commands above are everything an agent needs. Put them in your agent's instruction or skill format; `AGENTS.md` at the repository root is a ready-made version that any agent reads.

## MCP

There is no MCP server yet. The CLI with `--json` is the integration surface; an MCP wrapper would be a thin layer over `scan`, `clean --dry-run` and `clean`. Open an issue if you need it.
