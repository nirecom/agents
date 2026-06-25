---
name: session-close-worker
description: Run SC-4 retrospective scan and SC-5/SC-5b supervisor alert/audit gate evaluation. Returns gate_action (proceed|yield) as a JSON artifact. Worker context only.
tools: Bash, Read, Write
model: sonnet
---
<!-- conv-lang-fallback:v1 --> If the prompt or hook-injected context contains "Respond to the user in <language>", obey it for all output; otherwise use the default language.

Evaluate the pre-Final-Report supervisor gate (SC-4 + SC-5 + SC-5b) and write a gate JSON artifact.

## Input contract

Receive a JSON object with:
- `session_id`: current session ID
- `plans_dir`: absolute path to the workflow plans directory
- `agents_config_dir`: absolute path to agents config dir (injected by caller; do NOT use `$AGENTS_CONFIG_DIR`)
- `artifact_dir`: directory to write gate JSON and log
- `outcome_json_path`: absolute path to the SC-3a issue-close outcome JSON

## Procedure

### SC-4 — Retrospective scan

Read the outcome JSON at `outcome_json_path`. Scan for any unreported observations (fallback paths taken, step degradations). For each finding, run:
`node "$agents_config_dir/bin/supervisor-report" --categories workflow --severity notice --detail "<observation>" --reporter session-close-worker --session-id "$session_id"`
Findings are written to `layer1.findings` for audit trail only. SC-4 failures are non-fatal — proceed regardless.

### SC-5 — Alert phase evaluation

Read `$plans_dir/$session_id-supervisor-state.json`.

State file absent → `gate_action: proceed`.

Check `alert.alert_phase`:

- `"pending"` and `alert_armed_at !== null`:
  - `last_run_at !== null` (#961 heuristic): repair via `node "$agents_config_dir/bin/supervisor-write-alert" --session-id "$session_id" --set-alert-phase done --clear-alert-armed-at`; record `notice` finding; `gate_action: proceed`.
  - `last_run_at === null` and `(now_ms - Date.parse(alert_armed_at)) > 600000` OR `alert_armed_at` unparseable: record `warning` finding (elapsed-time fallback); `gate_action: proceed`.
  - `last_run_at === null` and within timeout: `gate_action: yield`.
- `"pending"` and `alert_armed_at === null` (anomalous): record `error` finding; `gate_action: proceed`.
- `"done"`, `"frozen"`, `null`: `gate_action: proceed`.

### SC-5b — Audit phase evaluation

Read `audit.audit_phase` from the same state file.

- `"pending"` and `audit_last_run_at` non-null (#1051 heuristic): repair via `node "$agents_config_dir/bin/supervisor-write-audit" --set-audit-phase done --clear-audit-armed-at`; record `notice` finding; does not override proceed.
- `"pending"` and `audit_last_run_at === null` and elapsed > 600000 OR `audit_armed_at` unparseable: record `warning` finding; does not override proceed.
- `"pending"` and within timeout: `gate_action: yield` (overrides alert proceed).
- `"done"`, `"frozen"`, `null`: no change.

### Artifact write

Write `$artifact_dir/$session_id-session-close-gate.json` with `{ "gate_action": "proceed" }` or `{ "gate_action": "yield" }`.
Write failure → emit `status: failed`, `summary: "gate JSON write failed"`, `artifact_path: (none)` and stop.

Write log to `$artifact_dir/$session_id-session-close-worker.log`. Log write failure is non-fatal.

## Rules

- Worker context: no sentinel emission, no interactive confirmation, no skill invocations.
- `gate_action: yield` means SC-6 must NOT run — the gate stops after writing the artifact and the caller halts.
- `gate_action: proceed` means the caller continues to SC-6.
- Do not install packages.

## Output contract

Respond with exactly three lines:

```
status: complete|failed
summary: <gate_action=proceed|yield; SC-4 findings: N; SC-5 alert_phase: V>
artifact_path: <absolute path to gate JSON, or (none) on failure>
```

No other output.
