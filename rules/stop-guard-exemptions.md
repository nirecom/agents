# Stop Guard Quiet-Layer Sentinels

Session-scoped declarations that keep the C4 premature-stop guard
(`hooks/stop-premature-stop-guard.js`) quiet during self-contained skill work.

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

The `{reason}` field is mandatory and non-empty for every sentinel above.

`<<WORKFLOW_NEXT_STEP_PAUSE: {reason}>>` / `<<WORKFLOW_NEXT_STEP_RESUME: {reason}>>`
are an existing member of the same class — see CLAUDE.md for how `ACTION=paused`
is handled; not duplicated here.

## When to Use

- `BACKGROUND_WORK_START` / `END`: work that will take multiple turns without
  a pending workflow-step gate to satisfy in between (e.g. a long subagent
  dispatch you are actively monitoring).

Do NOT use it to suppress C4 indefinitely — `BACKGROUND_WORK_START` expires
on its own after 4 hours.

## Implementation Details

- Marker file: `<workflowDir>/<sid>.background-work`.
- Session-scoped: only the current Claude Code session is affected.
- `.background-work` is fail-CLOSED on TTL (`hooks/lib/session-markers.js`
  `isBackgroundWorkInFlight`) — a missing/unparseable/expired `expires_at`
  is treated as not-in-flight.
- The marker is swept by `cleanupZombies` after 7 days as a last-resort
  backstop (`hooks/workflow-state/state-io/zombie-cleanup.js`).
- Full primitive-to-consumer correspondence: `hooks/lib/stop-exemption-policy.js`
  (`EXEMPTION_MATRIX`, declarative only — see its header comment for the
  registration procedure when adding a new condition).
