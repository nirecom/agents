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

At the start of Procedure, before the first plans-dir tool call, run:

```bash
PLANS_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null \
              || printf '%s\n' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}")
printf 'PLANS_DIR=%s\n' "$PLANS_DIR"
```

Capture the printed absolute path and substitute it for every `<PLANS_DIR>`
placeholder in the SKILL.md. Resolve once per invocation — reuse across
all subsequent steps.

- Read/Write/Edit args: literal absolute path.
- Subagent prompts: literal absolute path (subagents can't expand `$VAR` —
  see `feedback_cc_tool_env_var_handling`).
- Bash args: literal absolute path quoted (each Bash call has fresh shell state).

## Fallback chain

1. Primary: `bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"` — honours `.env`
   and exported overrides via the JS resolver.
2. Fallback: `"${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"` — respects an
   already-exported `WORKFLOW_PLANS_DIR`, but cannot read `.env`.

`AGENTS_CONFIG_DIR` is set in every Claude Code session; helper
unreachability is a configuration error.
