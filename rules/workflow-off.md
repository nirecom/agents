# Workflow Session Override (WORKFLOW_OFF)

Session-scoped escape hatch that suspends workflow enforcement for the current session.

## When to use

Appropriate for: trivial 1-file edits in private repos, `.env` adjustments, maintenance commits where full workflow overhead is disproportionate.
Do NOT use for: changes that touch public APIs, security boundaries, or shared infrastructure — run the full workflow for those.
Do NOT use to unblock a single hook-blocked sanctioned command: it disables enforcement session-wide and masks the root cause.
Need only the worktree isolation lifted (WORKTREE_OFF)? Same skill — WORKFLOW_OFF subsumes WORKTREE_OFF, so one sentinel covers both.

Never bypassed by this marker: `block-credentials.js`, `scan-outbound.js`, `enforce-system-ops.js` — credential access, the outbound scan, and OS-level system-ops safety stay armed.
Never bypassed either: the `AUTO_MERGE_PR=off` release refusal in `workflow-gate.js` — on a pull_request delivery only the human merges, on the web.

Sentinels, reason format, scope, and the mandatory restore step: `/enforce-workflow-off`.
Which hooks the marker does and does not bypass: `docs/architecture/claude-code/marker-bypass-contract.md`.
