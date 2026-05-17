# Resolve PLANS_DIR — Shared Protocol

Canonical documentation for the orchestrator-injects pattern. Every
consuming SKILL.md inlines the operational text below so that no skill
depends on this file being auto-loaded into Claude's context.

## Why this exists

- `WORKFLOW_PLANS_DIR` can override the default in `agents/.env`. Skill
  prompts must not embed the default literal path or write
  `${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}/...` inside a tool
  argument — the LLM does not pipe Read/Write paths through a shell,
  so the brace expansion never fires and the override is ignored.
- The canonical resolver is `hooks/lib/workflow-plans-dir.js`, exposed
  to non-Node callers as `bin/workflow-plans-dir`. JS hooks call it
  directly; everything else (skills, agents, scripts) goes through the
  bash bridge.

## Protocol (inlined verbatim into each consuming SKILL.md)

At the start of Procedure, before the first tool call that touches a
plans-directory path, the orchestrator runs the following Bash command:

```bash
PLANS_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null \
              || printf '%s\n' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}")
printf 'PLANS_DIR=%s\n' "$PLANS_DIR"
```

Then, in the orchestrator's subsequent assistant turn, it captures the
printed absolute path and substitutes it for every <PLANS_DIR>
placeholder appearing in the rest of the SKILL.md. Concretely:

- Read / Write / Edit file_path arguments use the resolved absolute path.
- Subagent prompts inject the resolved absolute path as a literal string
  (subagents cannot expand $VAR references — see
  feedback_cc_tool_env_var_handling).
- Bash commands embed the resolved absolute path quoted (no $PLANS_DIR
  references survive past the orchestrator turn; each Bash call's shell
  state is fresh).

## Cache

The resolution Bash call runs at most once per skill invocation. The
orchestrator reuses the same resolved path across all subsequent steps
in the same SKILL.

## Fallback chain (composed into the single Bash call above)

1. Primary: bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" — calls the
   canonical JS resolver, which honours .env and exported overrides.
2. Fallback (when helper unavailable): "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}".
   This still respects an already-exported WORKFLOW_PLANS_DIR before
   falling through to the home default — it does NOT silently ignore
   an exported override.

Note: the fallback expansion CANNOT read .env on its own. If
WORKFLOW_PLANS_DIR is set only in .env and the helper is unreachable,
the fallback resolves to the home default. AGENTS_CONFIG_DIR is set in
every Claude Code session; helper unreachability is a configuration error.
