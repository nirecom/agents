# Handoff Emergency Flush

Unconditional escape hatch: a session about to lose its working context must not have to earn this rule by matching a path glob.

A step here means a workflow step (one unit of `bin/workflow/next-step --list`); `docs/glossary.md` owns the term.

## What to record

This section is the single owner of what the main conversation writes into the handoff artifact.

Write only facts a fresh session cannot recover from any file:
- C — a user decision made in conversation that no artifact records yet.
- D — a deviation: a workaround, a fallback, a scope expansion, a flaky result.
- D — a rejected approach, with the reason it was rejected.
- F — an open question carried forward.

Never write:
- a progress snapshot, the next action, or a report that a step completed;
- a summary of the intent, outline, or detail plan — the plan file already owns it;
- a fact already recorded in substance, even with different wording.

Never write classes A, B, or E: hooks, CLIs, and skill procedures record them automatically.

## When to flush

Write a C/D/F fact at the moment it happens.

When a `[handoff check]` nudge arrives, check for C/D/F facts not yet recorded; if there are none, write nothing and continue.

Run the same omission check when the context window is nearly full, a compaction is imminent, or the session is being handed to another agent.

Write nothing outside the workflow active period: the CLI returns `WRITTEN=0 REASON=inactive` and records nothing.

Never flush the same fact twice: the writer skips a byte-identical repeat, so a re-flush after real progress is always correct.

## How to flush

Run `node "$AGENTS_CONFIG_DIR/bin/workflow/handoff-append" --class <C|D|F> --step <workflow step or -> --key <stable-id> --summary <what a fresh session needs> --pointer <path or -> --origin flush`.

One entry per distinct fact; `--key` is the dedup identity, so reuse the same key when re-recording the same fact and pick a new key for a new one.

Keep `--summary` under 300 characters and put the bulk in the file `--pointer` names — the artifact is a breadcrumb trail, never a second copy of the work.

Class vocabulary, the entry grammar, the active period, and the size caps: `docs/architecture/claude-code/handoff-artifact.md`.

## Scope

The flush never changes a verdict, a gate outcome, or a workflow step status — a lost breadcrumb must cost nothing but the breadcrumb.

Two readers consume the artifact read-only: `/resume-session` and the supervisor codex engine (`hooks/lib/supervisor-codex-input.js`).
