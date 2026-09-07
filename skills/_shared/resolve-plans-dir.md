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

At the start of Procedure, before the first plans-dir tool call, issue this one
standalone Bash call: `bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"`.

Read the absolute path it prints on stdout and substitute that literal text for
every `<PLANS_DIR>` placeholder in the SKILL.md. Do not assign it to a shell
variable — each Bash call has fresh shell state, so the consumer is you, not the
shell. Resolve once per invocation and reuse across all subsequent steps.

- Read/Write/Edit args: literal absolute path.
- Subagent prompts: literal absolute path (subagents can't expand `$VAR` —
  see `feedback_cc_tool_env_var_handling`).
- Bash args: literal absolute path quoted (each Bash call has fresh shell state).

## Fallback chain

Both steps live inside `bin/workflow-plans-dir`, so the caller issues one command:

1. Primary: the JS resolver, which honours `.env` and exported overrides.
2. Fallback: the exported `WORKFLOW_PLANS_DIR`, else `$HOME/.workflow-plans`.

`AGENTS_CONFIG_DIR` is set in every Claude Code session; helper
unreachability is a configuration error.
