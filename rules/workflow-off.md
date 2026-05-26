# Workflow Session Override (WORKFLOW_OFF)

Session-scoped escape hatch that suspends workflow enforcement for the current Claude Code session. Subsumes `WORKFLOW_ENFORCE_WORKTREE_OFF`.

## Sentinels

| Sentinel | Permission | Effect |
|---|---|---|
| `<<WORKFLOW_ENFORCE_WORKFLOW_OFF: <reason>>>` | **ask** (requires user approval) | Creates `${sid}.workflow-off` marker; suspends enforcement |
| `<<WORKFLOW_ENFORCE_WORKFLOW_ON: <reason>>>` | **allow** (auto-approved) | Removes marker; restores enforcement |

The `<reason>` field is mandatory and non-empty. Bare sentinel form (no `: <reason>`) is rejected.

## What is bypassed when WORKFLOW_OFF is active

| Hook | Bypassed? |
|---|---|
| `block-dotenv.js` | Yes — `.env` file access allowed |
| `scan-outbound.js` | Yes — outbound content scan skipped |
| `workflow-gate.js` | Yes — commit gate (step completion check) bypassed |
| `enforce-issue-close.js` | Yes — bare `gh issue close` allowed |
| `enforce-worktree.js` | Yes — main worktree writes allowed |
| `hooks/pre-commit` | Yes — commits from main worktree allowed |
| `enforce-system-ops.js` | **No — OS-level safety always enforced** |

## When to use

Appropriate for: trivial 1-file edits in private repos, `.env` adjustments, maintenance commits where full workflow overhead is disproportionate.

Do NOT use for: changes that touch public APIs, security boundaries, or shared infrastructure. Use the full workflow for those.

## Restoring enforcement

```
echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: done>>"
```

This is auto-allowed (no approval needed). Enforcement also restores automatically in the next session — markers are session-scoped.

## Scope

WORKFLOW_OFF is session-scoped: only the current Claude Code session (identified by its session ID) is affected. Other concurrent sessions remain at full enforcement.

WORKFLOW_OFF subsumes WORKTREE_OFF: when WORKFLOW_OFF is active, `enforce-worktree.js` is also bypassed. Emitting both sentinels is redundant — use WORKFLOW_OFF alone.
