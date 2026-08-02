---
name: sweep-supervisor-state
description: Remove test-contamination records from supervisor state files
user-invocable: true
model: sonnet
context: fork
---

# /sweep-supervisor-state

Remove the escape-hatch records that leaking test suites wrote into real supervisor state files under `~/.workflow-plans/`.

## Usage

Invoke `bin/sweep-supervisor-state.sh` with forwarded arguments.

Nothing is written unless `--apply` is passed — this member of the `/sweep` family is deliberately non-destructive by default, because it edits a governance audit trail rather than a regenerable derivative.

| Flag | Effect |
|---|---|
| `--apply` | Write the changes; the pre-modification files and a `manifest.json` are copied to a timestamped backup directory first. |
| `--ci-mode` | Emit a single-line JSON summary instead of prose. |
| `--list-signatures` | Print the reason allowlist and exit. |
| `--session <SID>` | Narrow the target set to one session. |

## When to use

Run after a test suite is found writing into the live plans dir, or when `bin/check-plans-dir-isolation.sh` reports W-candidates that already ran.

Preview with a flagless run first, confirm the reported records are test fixtures, then re-run with `--apply`.

## Guard

Sessions still in flight (`alert_phase=pending`, `audit_phase` pending or in progress, updated within 24h, or the current session) are always skipped. There is no override flag; `--session` narrows the target set but never relaxes the guard.
