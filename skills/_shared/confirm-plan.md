# Confirm Plan Artifact — Shared Protocol

Used by `clarify-intent` (CONFIRM_INTENT), `make-outline-plan` (CONFIRM_OUTLINE),
and `make-detail-plan` (CONFIRM_DETAIL) after writing a final plan artifact.
The gate check of CPA-3 alone is also used by `write-tests` (CONFIRM_TESTS), `write-code` (CONFIRM_CODE),
`update-docs` (CONFIRM_DOCS), and `worktree-start` (CONFIRM_WORKTREE).

## Steps

CPA-1 through CPA-3 always run. `CONFIRM_<STEP>` (default `on`) gates CPA-3's prompt only;
CPA-1's write and CPA-2's breadcrumb are unconditional.

**CPA-1 — Write the artifact.** Use the Write tool. No diff is shown in chat; CPA-2's breadcrumb is the only plan surface.

**CPA-2 — Breadcrumb.** `show-plan-link.js` PostToolUse syncs the artifact through
plan-sync and emits the breadcrumb after the Write returns:

    Plan file: <GitHub blob URL>

On a sync failure it emits the absolute local path plus a `[plan-sync]` status line instead.
This hook line is the **only** plan surface. The orchestrator MAY re-state the blob URL;
it MUST NOT emit any local path representation — no duplication, translation, paraphrase,
markdown link, relative/tilde path, `file:///` URI, or path appended to a Japanese sentence.
Never copy the blob URL into a PR body, `history.md`, `CHANGELOG.md`, or a public issue —
the plan repo is private. Leak guard and the `.private-info-blocklist` registration:
`docs/architecture/claude-code/plan-sync.md`.
Enforcement: `stop-confirm-plan-guard.js` Stop hook structurally blocks turns where a `WORKFLOW_PLANS_DIR` path appears in the last assistant message (always active, regardless of `CONFIRM_<STEP>`).

**CPA-3 — Gate check (`next-step --gate`).**
Run the standalone command `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --gate` and follow the `GATE_ACTION` line of its stdout.
Never interpret ON/OFF yourself, and never read `GATE_ACTION` as a different value.
`--gate` judges the RECORDED current step, which can lag the step the calling skill is on: when the step named at the start of `REASON` (`<step>: CONFIRM_X=...`) is not your own step, treat the result as `none`.
- `proceed`: take the caller's OFF branch (plan stages: print a one-paragraph prose summary without duplicating the breadcrumb path, then proceed). When `GATE_HINT` carries a warning sentence (e.g. a failed scope-change check), relay it to the user in that summary.
- `ask`: when `GATE_HINT` names a scope change or carries a warning, show it to the user first; then take the caller's ON branch (plan stages: the sentinel procedure below; write-tests / write-code / update-docs / worktree-start: the skill's own ON branch — a pre-action gate asks via `AskUserQuestion`, a post-action gate presents the result and continues).
  - Plan stages emit the matching sentinel via Bash (no `AskUserQuestion` call): `echo "<<WORKFLOW_CONFIRM_{STAGE}: {one-line summary}>>"`, with `<STAGE>` = `INTENT` / `OUTLINE` / `DETAIL` per the caller.
  - In the SAME response, after the CONFIRM Bash echo, also issue the next tool_use (Skill or Bash) per the caller's per-site reminder. Do NOT end the response on the CONFIRM echo.
  - `confirm-checkpoint.js` (PreToolUse) surfaces the dialog; `stop-confirm-plan-guard.js` (Stop, Layer 2) blocks the turn if no stage-valid follow-up follows the CONFIRM sentinel in the same turn.
  - **Allow**: continue with the next tool_use already in flight.
  - **Deny**: ask what to change, write edits, loop back to CPA-1.
- `present-and-stop` (detail only): follow `GATE_HINT` — present, then end the turn without the completion sentinel or `--advance`.
  - User approves: run the standalone command `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --gate --scope-change-approved` and follow its `GATE_ACTION`.
  - User asks for changes: loop back to MDP-5.
- `none`: take neither branch; report `REASON` to the user and end the turn without the completion sentinel or `--advance` — reaching a gate section with no gate means drifted state or an unresolved session.
- Pass `--scope-change-approved` only once, right after the user's approval reply; never on any other call.
- The `GATE_CONFIRM_<X>` line of the normal next-step output is display-only; never branch on it — branch only on `--gate`.
- When a later step needs the gate value or branch again, rerun `--gate` there; never reuse a remembered or summarized value.

## Notes

- Revise loop has no explicit cap — trust the user to say "Proceed".
- Do not paste the full artifact in chat — the breadcrumb is sufficient.
- Each skill defines what "Revise" means concretely.
- `CONFIRM_*` sentinels are for plan-stage review only. The sole user gate before the final publish action (merge in on-mode; commit+push in off-mode) is `WORKFLOW_USER_VERIFIED` — see `skills/_shared/user-verified.md`. Do not add upstream CONFIRM gates for post-action notifications.
- The CPA-3 `--gate` procedure is shared by all seven confirm gates; the step→gate map lives in `hooks/lib/confirm-gate/step-gate-map.js`.
