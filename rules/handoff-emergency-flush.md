# Handoff Emergency Flush

Unconditional escape hatch: a session about to lose its working context must not have to earn this rule by matching a path glob.

## When to flush

Flush when you notice any of: the context window is nearly full, a compaction is imminent or has just happened, the session is being handed to another agent, or a `[handoff pressure]` nudge arrived this turn.

Flush also when a step ends with knowledge the workflow state file cannot hold — a workaround, a rejected approach, a blocked gate, a partially-applied edit.

Never flush the same fact twice: the writer skips a byte-identical repeat, so a re-flush after real progress is always correct.

## How to flush

Run `node "$AGENTS_CONFIG_DIR/bin/workflow/handoff-append" --class <A-G> --step <workflow step or -> --key <stable-id> --summary <what a fresh session needs> --pointer <path or -> --origin flush`.

One entry per distinct fact; `--key` is the dedup identity, so reuse the same key when re-recording the same fact and pick a new key for a new one.

Keep `--summary` under 300 characters and put the bulk in the file `--pointer` names — the artifact is a breadcrumb trail, never a second copy of the work.

Class vocabulary, the entry grammar, and the size caps: `docs/architecture/claude-code/handoff-artifact.md`.

## Scope

The flush never changes a verdict, a gate outcome, or a workflow step status — a lost breadcrumb must cost nothing but the breadcrumb.

`/resume-session` reads the artifact back; nothing else consumes it.
