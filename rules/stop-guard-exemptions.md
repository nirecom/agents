# Stop Guard Quiet-Layer Sentinels

Session-scoped declarations that keep the C4 premature-stop guard
(`hooks/stop-premature-stop-guard.js`) quiet during self-contained skill
work or a single-turn wait for a user answer.

## Scope

These markers are **not** an enforcement bypass. They never affect
`enforce-*` / `block-*` hooks — only whether C4 re-nudges the current
turn. The bypass contract (what WORKFLOW_OFF actually suspends) is
tracked separately in
`docs/architecture/claude-code/marker-bypass-contract.md`; these markers
are deliberately absent from that table, the same way `.next-step-paused`
(#1607) is.

## Sentinels

| Sentinel | Permission | Effect |
|---|---|---|
| `<<WORKFLOW_BACKGROUND_WORK_START: {reason}>>` | **ask** | Sets `.background-work`; quiets C4 and next-step for up to 4 hours (TTL) |
| `<<WORKFLOW_BACKGROUND_WORK_END: {reason}>>` | **allow** | Clears the marker early |
| `<<WORKFLOW_AWAITING_USER: {reason}>>` | **ask** | Declares "this turn ends awaiting a user answer"; quiets C4 for the next Stop only |
| `<<WORKFLOW_AWAITING_USER_END: {reason}>>` | **allow** | Cancels the declaration (idempotent if already consumed) |

The `{reason}` field is mandatory and non-empty for every sentinel above.

`<<WORKFLOW_NEXT_STEP_PAUSE: {reason}>>` / `<<WORKFLOW_NEXT_STEP_RESUME: {reason}>>`
are an existing member of the same class — see CLAUDE.md for how `ACTION=paused`
is handled; not duplicated here.

## When to Use

- `BACKGROUND_WORK_START` / `END`: work that will take multiple turns without
  a pending workflow-step gate to satisfy in between (e.g. a long subagent
  dispatch you are actively monitoring).
- `AWAITING_USER`: the current turn ends with a question and no further action
  is possible until the user replies — declare it so C4 does not treat the
  stop as premature.

Do NOT use either to suppress C4 indefinitely — `BACKGROUND_WORK_START` expires
on its own after 4 hours; `AWAITING_USER` is consumed automatically on the next
Stop regardless of whether `_END` was emitted.

## Implementation Details

- Marker files: `<workflowDir>/<sid>.background-work`,
  `<workflowDir>/<sid>.awaiting-user`.
- Session-scoped: only the current Claude Code session is affected.
- `.background-work` is fail-CLOSED on TTL (`hooks/lib/session-markers.js`
  `isBackgroundWorkInFlight`) — a missing/unparseable/expired `expires_at`
  is treated as not-in-flight.
- `.awaiting-user` has no TTL; it is consumed on read by C4
  (`consumeAwaitingUser`) the first time it is evaluated after being set —
  a forgotten `_END` cannot silence C4 beyond the next Stop.
- Both markers are swept by `cleanupZombies` after 7 days as a last-resort
  backstop (`hooks/workflow-state/state-io/zombie-cleanup.js`).
- Full primitive-to-consumer correspondence: `hooks/lib/stop-exemption-policy.js`
  (`EXEMPTION_MATRIX`, declarative only — see its header comment for the
  registration procedure when adding a new condition).
