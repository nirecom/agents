# Resolve PLANS_DIR — Shared Protocol

Canonical docs for the orchestrator-injects pattern. Each consuming SKILL.md
inlines the snippet below — this file is reference, not auto-loaded.

## Why

`WORKFLOW_PLANS_DIR` (from `agents/.env` or env) overrides the default.
Tool args (Read/Write/Edit/subagent prompts) are not shell-expanded, so
embedding `${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}` directly in those
args silently ignores the override. The orchestrator must resolve the path
once via Bash, then substitute the literal absolute path everywhere.

Canonical resolver: `hooks/lib/workflow-plans-dir.js` (used by JS hooks).
Non-Node callers go through `bin/workflow-plans-dir` (Bash bridge).

## Protocol (inlined into each consuming SKILL.md)

At the start of Procedure, before the first plans-dir tool call, run `bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"` as one bare command and read its stdout — an absolute path.

Never assign that command to a variable and echo it back: the bare command already prints the answer.

Substitute the printed path for every `<PLANS_DIR>` placeholder in the SKILL.md. Resolve once per invocation — reuse across all subsequent steps.

- Read/Write/Edit args: literal absolute path.
- Subagent prompts: literal absolute path (subagents can't expand `$VAR` —
  see `feedback_cc_tool_env_var_handling`).
- Bash args: literal absolute path quoted (each Bash call has fresh shell state).

## Fallback chain

`bin/workflow-plans-dir` owns the whole chain — `WORKFLOW_PLANS_DIR` when set, else `$HOME/.workflow-plans`. Callers must not restate it.

Never wrap the call in a caller-side `||` fallback: it duplicates the bridge's own contract and forces the prohibited capture-then-echo form.

`AGENTS_CONFIG_DIR` is set in every Claude Code session; helper
unreachability is a configuration error.
