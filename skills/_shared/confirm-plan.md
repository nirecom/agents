# Confirm Plan Artifact — Shared Protocol

Used by `clarify-intent` (CONFIRM_INTENT), `make-outline-plan` (CONFIRM_OUTLINE),
and `make-detail-plan` (CONFIRM_DETAIL) after writing a final plan artifact.
The gate check of CPA-3 alone is also used by `write-tests` (CONFIRM_TESTS), `write-code` (CONFIRM_CODE),
`update-docs` (CONFIRM_DOCS), and `worktree-start` (CONFIRM_WORKTREE).

## Steps

CPA-1 through CPA-3 run regardless of the gate; the gate (`CONFIRM_<STEP>`, default `on`) decides how CPA-2 closes and which branch CPA-3 takes.
CPA-2's plan-link line belongs to the turn that wrote the plan; a later turn writes it only to present the plan again.

**CPA-1 — Write the artifact.** Use the Write tool. No diff is shown in chat; CPA-2's breadcrumb is the only plan surface.

**CPA-2 — Plan link.** After the Write returns, `show-plan-link.js` syncs the artifact through plan-sync and hands you its plan-link line as additional context: the blob URL plus the local path when the plan was published, otherwise the local path plus a reason.
Each stage's gate sets the duty. OFF: write the line as-is once inside the summary of the turn that wrote the plan.
ON / ERROR: end the last text block of the presentation turn with the plan-link lines, with no text after them; CPA-3 decides whether the turn then closes.
When this environment can publish the plan but the line has no URL, publish it first (rewrite it through the Write or Edit tool so plan-sync runs), then present it.
To look the line up later, run `node "$AGENTS_MAIN_ROOT/bin/plan-link" --stage <stage>` and write its output as-is.
Never hand the plan over with `SendUserFile`.
Never copy the blob URL into a PR body, `history.md`, `CHANGELOG.md`, or a public issue — the plan repo is private; leak guard: `docs/architecture/claude-code/plan-sync.md`.
Enforcement (Stop): `stop-confirm-plan-guard.js` reads each stage's gate and blocks a turn that wrote a plan without its line, a link line of an unapproved stage followed by other text, or an unpublished plan where a URL can be made.
`stop-confirm-plan-guard.js` records a presentation receipt only for a turn it lets through that closes on the link lines; a blocked turn records none and keeps earlier receipts.
When the transcript tail is undecidable, it records each stage the final message closes on, never blocks, and tells the user which stages got no receipt.
Enforcement (PreToolUse): `confirm-checkpoint.js` passes a CONFIRM echo to the dialog only when the presentation receipt matches the plan's current path, link, and content, and spends the receipt.
On a mismatch, or when it cannot verify, it denies and asks you to present the plan again; there is no cap.

**CPA-3 — Gate check (`next-step --gate`).**
Run the standalone command `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --gate` and follow the `GATE_ACTION` line of its stdout.
Plan stages: before `--gate`, run `check-glossary-drift --stage <intent|outline|detail> --record` per `skills/_shared/glossary-drift-check.md`, and put that file's approval list in the Presentation turn, the `present-and-stop` presentation, and the `proceed` summary.
Never interpret ON/OFF yourself, and never read `GATE_ACTION` as a different value.
`--gate` judges the RECORDED current step, which can lag the step the calling skill is on: when the step named at the start of `REASON` (`<step>: CONFIRM_X=...`) is not your own step, treat the result as `none`.
- `proceed`: take the caller's OFF branch (plan stages: print a one-paragraph prose summary, then proceed; the summary carries the CPA-2 plan-link line once). When `GATE_HINT` carries a warning sentence (e.g. a failed scope-change check), relay it to the user in that summary.
- `ask`: when `GATE_HINT` names a scope change or carries a warning, show it to the user first; then take the caller's ON branch (plan stages: the sentinel procedure below; write-tests / write-code / update-docs / worktree-start: the skill's own ON branch — a pre-action gate asks via `AskUserQuestion`, a post-action gate presents the result and continues).
  - Plan stages run three steps with no `AskUserQuestion` call; `<STAGE>` = `INTENT` / `OUTLINE` / `DETAIL` per the caller.
  - Presentation: end the final body text with "The approval dialog follows this message; if it does not appear, reply once you have reviewed the plan." and then the CPA-2 plan-link line as the last line, then close the turn.
  - CONFIRM echo (main path): when the turn end is blocked with a `[confirm-plan] continue:` prompt, emit only `echo "<<WORKFLOW_CONFIRM_{STAGE}: {one-line summary}>>"` as your next message.
  - CONFIRM echo (fallback): when no prompt came, let the turn close and wait for the user's reply; on a change request, revise and loop back to CPA-1, otherwise emit only that echo in the next turn.
  - Denied echo: present the plan again as the deny reason says, close the turn, and echo only after the user's reply.
  - Next response: **Allow** → run the caller's completion, then co-emit the caller's next tool_use (Skill or Bash) in the same turn; **Deny** → the turn stops, so wait for the user's revision instructions.
  - `confirm-checkpoint.js` (PreToolUse) surfaces the dialog; `stop-confirm-plan-guard.js` (Stop, Layer 2) blocks the turn when no stage-valid follow-up comes after the Allowed echo's result in that same turn.
- `present-and-stop` (detail only): follow `GATE_HINT` — present, then end the turn without the completion sentinel or `--advance`.
  - User approves: run the standalone command `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --gate --scope-change-approved` and follow its `GATE_ACTION`.
  - User asks for changes: loop back to MDP-5.
- `none`: take neither branch; report `REASON` to the user and end the turn without the completion sentinel or `--advance` — reaching a gate section with no gate means drifted state or an unresolved session.
- Pass `--scope-change-approved` only once, right after the user's approval reply; never on any other call.
- The `GATE_CONFIRM_<X>` line of the normal next-step output is display-only; never branch on it — branch only on `--gate`.
- When a later step needs the gate value or branch again, rerun `--gate` there; never reuse a remembered or summarized value.

## Notes

- Revise loop has no explicit cap — trust the user to say "Proceed".
- Do not paste the full artifact in chat — the plan-link line is sufficient.
- Each skill defines what "Revise" means concretely.
- `CONFIRM_*` sentinels are for plan-stage review only. The sole user gate before the final publish action (merge in on-mode; commit+push in off-mode) is `WORKFLOW_USER_VERIFIED` — see `skills/_shared/user-verified.md`. Do not add upstream CONFIRM gates for post-action notifications.
- The CPA-3 `--gate` procedure is shared by all seven confirm gates; the step→gate map lives in `hooks/lib/confirm-gate/step-gate-map.js`.
