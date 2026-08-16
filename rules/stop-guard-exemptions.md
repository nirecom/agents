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

## Three prongs

### (a) `write_code` in flight — automatic, no sentinel

C4 does not fire while the session's `write_code` step is `in_progress`
and within its 4-hour TTL.

- The declaration is the `WORKFLOW_MARK_STEP_write_code_in_progress` sentinel that `/write-code` already emits — nothing extra to say.
- There is no dedicated marker file and no START/END sentinel pair.
- Predicate: `isWriteCodeInFlight` in `hooks/workflow-state/lifecycle.js`; fail-CLOSED (unreadable state, wrong status, missing/unparseable `updated_at`, or TTL exceeded → not in flight).
- next-step is **not** quieted: `ACTION=invoke write-code` while `/write-code` runs is correct guidance, so only the Stop hook's forced nudge is silenced.

### (b) A delegated step in flight — automatic, no sentinel (#2013)

The same rule as (a), widened to the delegated-dispatch steps
(`research`, `detail`, `write_tests`, `review_tests`). A dispatch through the
Agent / Task / Skill tools is the declaration: the PostToolUse hook
`hooks/postuse-step-in-flight-mark.js` records the session's current step
`in_progress`, and C4 stays quiet for the same 4-hour TTL.

- Nothing to emit by hand — do **not** pair a dispatch with `NEXT_STEP_PAUSE`.
- Allow-list + TTL SSOT: `hooks/lib/step-in-flight-policy.js`. Predicate:
  `isStepInFlight` / `anyStepInFlight` in `hooks/workflow-state/lifecycle.js`.
- Expiry is not silence: once the TTL passes, the stale `in_progress` record is
  reported as a mechanism failure (`hooks/lib/mechanism-failure.js`) by the
  UserPromptSubmit check and by C4 itself, so a dispatch that never returns
  surfaces instead of hanging (#1979 / #1997).

### (c) Every other long-running work — `NEXT_STEP_PAUSE`

For long-running work outside the in-flight prongs above, use
`<<WORKFLOW_NEXT_STEP_PAUSE: {reason}>>`; resume with
`<<WORKFLOW_NEXT_STEP_RESUME: {reason}>>`. See CLAUDE.md for how
`ACTION=paused` is handled.

**Migration note (#1665):** this replaces the retired TTL-based
quiet-layer START / END sentinel pair, which is gone.
The quiet strength is identical (C4 and next-step both silenced). The one
property that changed is expiry: the retired pair self-expired after 4
hours, whereas a pause persists until an explicit `NEXT_STEP_RESUME`. Issue the
resume sentinel by hand when the work ends.

**Scope + expiry note (#1624):** a pause marker is v2 — it carries `for_step`
(default `any` when the reason has no `[for=<step>]` tag), an `expires_at`, and
an `audit` object. A pause therefore quiets only the step it was taken for, and
a marker that cannot prove freshness (expired, v1/legacy, malformed) is inactive
rather than silencing the session forever.

## Implementation Details

- Session-scoped: only the current Claude Code session is affected.
- `.next-step-paused` is a marker file swept by `cleanupZombies` after 7 days as a last-resort backstop (`hooks/workflow-state/state-io/zombie-cleanup.js`); prongs (a) and (b) have no marker file to sweep. The `.stall-reported` ledger (#1997) is swept on the same 7-day rule.
- Full primitive-to-consumer correspondence: `hooks/lib/stop-exemption-policy.js`
  (`EXEMPTION_MATRIX`, declarative only — see its header comment for the
  registration procedure when adding a new condition).
