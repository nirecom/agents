# Confirm Plan Artifact — Shared Protocol

Used by `clarify-intent` (CONFIRM_INTENT), `make-outline-plan` (CONFIRM_OUTLINE),
and `make-detail-plan` (CONFIRM_DETAIL) after writing a final plan artifact.
The gate check of CPA-3 alone is also used by `write-tests` (CONFIRM_TESTS), `write-code` (CONFIRM_CODE),
`update-docs` (CONFIRM_DOCS), and `worktree-start` (CONFIRM_WORKTREE).

## Steps

CPA-1 through CPA-3 always run. `CONFIRM_<STEP>` (default `on`) gates CPA-1's diff preview
and CPA-3's prompt; CPA-2's plan link is unconditional.

**CPA-1 — Write the artifact.** Use the Write tool. The `show-diff.js` PreToolUse
hook emits the diff as a `systemMessage`. When `CONFIRM_<STEP>=off`, the hook
suppresses the preview — CPA-3's prose summary substitutes.

**CPA-2 — Plan link.** `show-plan-link.js` PostToolUse syncs the artifact through plan-sync after the Write returns.
It hands you the plan's GitHub blob URL, or the reason there is none, as `additionalContext` (`[plan-link]`).
Write that blob URL in your response text — the user sees a plan only through the URL you write.
When no URL exists, state the reason in one line; the hook then shows the user a `[plan-sync]` breadcrumb `systemMessage`.
To print the URL again later (e.g. the user asks where the plan is), run `node "$AGENTS_CONFIG_DIR/bin/plan-link"` (add `--session <id>` when the plan files carry a timestamp id instead of the session id).
MUST NOT emit any local path representation — no duplication, translation, paraphrase,
markdown link, relative/tilde path, `file:///` URI, or path appended to a Japanese sentence.
Never send a plan with `SendUserFile` — `block-send-user-file.js` denies it.
Never copy the blob URL into a PR body, `history.md`, `CHANGELOG.md`, or a public issue —
the plan repo is private. Leak guard and the `.private-info-blocklist` registration:
`docs/architecture/claude-code/plan-sync.md`.
Enforcement: `stop-confirm-plan-guard.js` Stop hook structurally blocks turns where a `WORKFLOW_PLANS_DIR` path appears in the last assistant message (always active, regardless of `CONFIRM_<STEP>`).
It also blocks (Layer 3) a turn that wrote or CONFIRMed a published plan without that plan's blob URL in the turn's response text.
Like Layers 1 and 2, Layer 3 is a one-shot nudge: it stands down on the retry Stop (`stop_hook_active`), so the retry itself must carry the URL.

**CPA-3 — Gate check (`next-step --gate`).**
Run the standalone command `node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --gate` and follow the `GATE_ACTION` line of its stdout.
Never interpret ON/OFF yourself, and never read `GATE_ACTION` as a different value.
`--gate` judges the RECORDED current step, which can lag the step the calling skill is on: when the step named at the start of `REASON` (`<step>: CONFIRM_X=...`) is not your own step, treat the result as `none`.
- `proceed`: take the caller's OFF branch (plan stages: print a one-paragraph prose summary with the CPA-2 blob URL and no local path, then proceed). When `GATE_HINT` carries a warning sentence (e.g. a failed scope-change check), relay it to the user in that summary.
- `ask`: when `GATE_HINT` names a scope change or carries a warning, show it to the user first; then take the caller's ON branch (plan stages: the sentinel procedure below; write-tests / write-code / update-docs / worktree-start: the skill's own ON branch — a pre-action gate asks via `AskUserQuestion`, a post-action gate presents the result and continues).
  - Before the CONFIRM echo, in the SAME response, write the plan's CPA-2 blob URL in your response text, so the user can open the plan while the dialog is up.
    When that URL is no longer in your context (resumed or compacted session, a CONFIRM on a later turn), run `node "$AGENTS_CONFIG_DIR/bin/plan-link"` first and write the URL it prints.
  - Never put the URL inside the CONFIRM echo or its one-line summary — the URL belongs in body text only.
  - Plan stages emit the matching sentinel via Bash (no `AskUserQuestion` call): `echo "<<WORKFLOW_CONFIRM_{STAGE}: {one-line summary}>>"`, with `<STAGE>` = `INTENT` / `OUTLINE` / `DETAIL` per the caller.
  - In the SAME response, after the CONFIRM Bash echo, also issue the next tool_use (Skill or Bash) per the caller's per-site reminder. Do NOT end the response on the CONFIRM echo.
  - `confirm-checkpoint.js` (PreToolUse) surfaces the dialog and hands you the blob URL again as `additionalContext` — after Allow or Deny, write it in your response text if you have not yet; `stop-confirm-plan-guard.js` (Stop, Layer 2) blocks the turn if no stage-valid follow-up follows the CONFIRM sentinel in the same turn.
  - **Allow**: continue with the next tool_use already in flight.
  - **Deny**: ask what to change, write edits, loop back to CPA-1.
- `present-and-stop` (detail only): follow `GATE_HINT` — present, then end the turn without the completion sentinel or `--advance`.
  - User approves: run the standalone command `node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --gate --scope-change-approved` and follow its `GATE_ACTION`.
  - User asks for changes: loop back to MDP-5.
- `none`: take neither branch; report `REASON` to the user and end the turn without the completion sentinel or `--advance` — reaching a gate section with no gate means drifted state or an unresolved session.
- Pass `--scope-change-approved` only once, right after the user's approval reply; never on any other call.
- The `GATE_CONFIRM_<X>` line of the normal next-step output is display-only; never branch on it — branch only on `--gate`.
- When a later step needs the gate value or branch again, rerun `--gate` there; never reuse a remembered or summarized value.

## Notes

- Revise loop has no explicit cap — trust the user to say "Proceed".
- Do not paste the full artifact in chat — diff + blob URL are sufficient.
- Each skill defines what "Revise" means concretely.
- `CONFIRM_*` sentinels are for plan-stage review only. The sole user gate before the final publish action (merge in on-mode; commit+push in off-mode) is `WORKFLOW_USER_VERIFIED` — see `skills/_shared/user-verified.md`. Do not add upstream CONFIRM gates for post-action notifications.
- The CPA-3 `--gate` procedure is shared by all seven confirm gates; the step→gate map lives in `hooks/lib/confirm-gate/step-gate-map.js`.
