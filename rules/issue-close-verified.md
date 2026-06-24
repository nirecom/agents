# ISSUE_CLOSE_VERIFIED Sentinel

Session-scoped bypass that allows `gh issue close` through Claude's Bash tool
without triggering the `enforce-issue-close.js` guard.

## Scope

Bypasses only `enforce-issue-close.js`.
Does NOT bypass `enforce-worktree.js`, `enforce-system-ops.js`, `workflow-gate.js`,
or any other hook. Does NOT arm the supervisor (no `reportSentinel()` call).

## Sentinels

| Sentinel | Permission | Effect |
|---|---|---|
| `<<WORKFLOW_ISSUE_CLOSE_VERIFIED: <reason>>>` | **ask** (requires user approval) | Opens bypass window — `gh issue close` allowed from Bash tool |
| `<<WORKFLOW_ISSUE_CLOSE_VERIFIED_END: <reason>>>` | **allow** (auto-approved) | Closes bypass window — guard restored |

The `<reason>` field is mandatory and non-empty.

## When to Use

Appropriate for planned admin operations:
- Closing known obsolete issues (batch triage)
- Closing incidentally-fixed issues not covered by a current session

Do NOT use to bypass the standard close path (`/issue-close-finalize`).
For workflow-managed closes, use `/issue-close-stage` + `/issue-close-finalize`.

## Implementation Details

- Marker file: `<workflowDir>/<sid>.issue-close-verified`
- Session-scoped: only the current Claude Code session is affected
- Auto-cleaned by `cleanupZombies` after 7 days
- `ISSUE_CLOSE_SKILL=1` (skill-internal bypass) continues to work independently
