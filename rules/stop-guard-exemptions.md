# Stop Guard Quiet Layer

Session-scoped conditions that keep the C4 premature-stop guard
(`hooks/stop-premature-stop-guard.js`) quiet during long-running work.

## Scope

These conditions are **not** an enforcement bypass. They never affect
`enforce-*` / `block-*` hooks — only whether C4 re-nudges the current
turn. The bypass contract (what WORKFLOW_OFF actually suspends) is
tracked separately in
`docs/architecture/claude-code/marker-bypass-contract.md`; this layer
is deliberately absent from that table, the same way `.next-step-paused`
(#1607) is.

## Two prongs

### (a) `write_code` in flight — automatic, no sentinel

C4 does not fire while the session's `write_code` step is `in_progress`
and within its 4-hour TTL.

- The declaration is the `WORKFLOW_MARK_STEP_write_code_in_progress` sentinel that `/write-code` already emits — nothing extra to say.
- There is no dedicated marker file and no START/END sentinel pair.
- Predicate: `isWriteCodeInFlight` in `hooks/workflow-state/lifecycle.js`; fail-CLOSED (unreadable state, wrong status, missing/unparseable `updated_at`, or TTL exceeded → not in flight).
- next-step is **not** quieted: `ACTION=invoke write-code` while `/write-code` runs is correct guidance, so only the Stop hook's forced nudge is silenced.

### (b) Every other long-running work — `NEXT_STEP_PAUSE`

For long-running work outside `write_code` (e.g. a monitored subagent
dispatch), use `<<WORKFLOW_NEXT_STEP_PAUSE: {reason}>>`; resume with
`<<WORKFLOW_NEXT_STEP_RESUME: {reason}>>`. See CLAUDE.md for how
`ACTION=paused` is handled.

**Migration note (#1665):** this replaces the retired TTL-based
quiet-layer START / END sentinel pair, which is gone.
The quiet strength is identical (C4 and next-step both silenced). The one
property that changed is expiry: the retired pair self-expired after 4
hours, whereas a pause has **no TTL** and persists until an explicit
`NEXT_STEP_RESUME`. Issue the resume sentinel by hand when the work ends —
forgetting it leaves the session quiet indefinitely.

## Implementation Details

- Session-scoped: only the current Claude Code session is affected.
- `.next-step-paused` is a marker file swept by `cleanupZombies` after 7 days as a last-resort backstop (`hooks/workflow-state/state-io/zombie-cleanup.js`); prong (a) has no marker file to sweep.
- Full primitive-to-consumer correspondence: `hooks/lib/stop-exemption-policy.js`
  (`EXEMPTION_MATRIX`, declarative only — see its header comment for the
  registration procedure when adding a new condition).
