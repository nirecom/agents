# PM Contact (pre-PR and review)

Procedures for `/commit-push` CP-1b (tell the assigned PM session before CP-2 creates the PR) and for `## Review request` (the PM review at plan confirmation and before `USER_VERIFIED`).
Design and rationale: `docs/architecture/cross-session-messaging.md` §7; header, ack and exit codes: §4 and §6 there.
ListAgents, SendMessage and AskUserQuestion are model tools, so these steps stay in the prompt rather than a CLI. <!-- askuser-none -->

## Recording the PM

- On receiving a `[peer-msg v1]` header with `role=pm`, write its `from-session` and `pm-issues` under `Facts to carry over` in session-progress.md, so they survive compaction.

## Skip conditions

These apply to CP-1b only; `## Review request` never skips on them.

- Run `node "$AGENTS_MAIN_ROOT/bin/workflow/pr-state"` first; on `PR_STATE=OPEN` skip this procedure (the PR and the contact already happened).
- Never skip because of `--wip`: a `--wip` run can still create the PR.

## PPC-1. Decide whether a PM is assigned

- Run `node "$AGENTS_MAIN_ROOT/bin/pm-notify" check-header --tag <PM tag> --pm-issues <recorded pm-issues> --closes <closes_issues>`; with no recorded header, pass `--tag` from `bin/pm-state owner` of `closes_issues` and `--pm-issues ""`.
- Treat the PM as assigned when a `role=pm` header was recorded or `OWNER_TAG=` is non-empty (an `owner` hit counts without a record).
- `RESULT=mismatch` or `RESULT=undecidable` → AskUserQuestion (`metadata.source=pm-pre-pr-contact.header-mismatch`) showing both sides: the header's `pm-issues` and `EXTRA=` / `MISSING=` / `OWNER_TAG=` / `REASON=`.
- `REASON=pm-tag-renamed` → use `NEW_TAG=` as the tag and rerun the check.
- With no record and no `owner` hit, skip the rest of this procedure and continue to CP-2.

## PPC-2. Confirm the PM is in ListAgents

- Run ListAgents and write its output to a file under the session scratchpad with the Write tool.
- Count the PM as present only when one entry's name matches `PM_NAME_PREFIX_RE`, contains the first number of the recorded `pm-issues`, and ends with the `SESSION_NAME_SUFFIX_RE` suffix (`hooks/lib/session-name.js`): ` sid-` followed by the first 8 characters of the recorded `from-session`.
- When no entry qualifies, including a matching name with a different suffix, stop and AskUserQuestion (`metadata.source=pm-pre-pr-contact.pm-missing`): the PM may not have been started again by hand.

## PPC-3. Send

- Run `node "$AGENTS_MAIN_ROOT/bin/peer-msg" header --agents-file <list file>` (no `--role`: this session is not the PM) and keep its `msg-id`.
- Run `node "$AGENTS_MAIN_ROOT/bin/find-peer" --session <PM full id> --agents-file <list file>` and SendMessage to its `DESTINATION`, with the header as the first line and the PR summary after it.
- On a non-zero exit from either CLI, stop and report its `REASON` to the user; never send to a guessed destination.

## PPC-4. Wait for the ack

- Emit `<<WORKFLOW_NEXT_STEP_PAUSE: waiting for PM ack before PR creation>>`.
- Start `node "$AGENTS_MAIN_ROOT/bin/peer-msg" timer --msg-id <msg-id> --seconds 600` in the background.
- When a `[peer-ack v1]` arrives, write it to a file and run `node "$AGENTS_MAIN_ROOT/bin/peer-msg" verify --msg-id <msg-id> --expect-session <PM full id> --ack-file <ack file>`.
- On exit 0, emit `<<WORKFLOW_NEXT_STEP_RESUME: PM ack received>>` and continue to CP-2.
- When the timer ends first or `verify` exits 3 or 4, emit the RESUME sentinel and AskUserQuestion (`metadata.source=pm-pre-pr-contact.ack-failed`).
- Never resend automatically; this procedure adds no gate.

## Review request

Run when the `audit-wait` hint of `next-step --gate` names it (plan confirmation) or at `/get-release-approval` GA-1 PM review (user_verified), with the PM assigned per PPC-1. Gate, record and round cap: `docs/architecture/cross-session-messaging.md` §7.

- **RR-1.** Run `node "$AGENTS_MAIN_ROOT/bin/pm-instructions" --timing before-plan-confirm --session <sid>` (plan) or `--timing before-user-verification` (user_verified) and follow its output.
- **RR-2.** Send by PPC-2 and PPC-3 with a pointer-only body: the issue number whose `## Changes` section the PM reads itself, the trigger, and the audit run id from the gate hint, the plan file path from `bin/plan-link --step <step>` and this session's transcript path (plan) or the PR URL, round and HEAD SHA (user_verified).
  - For user_verified, first run `node "$AGENTS_MAIN_ROOT/bin/review-rounds" append --session <this session id> --format pm-review --request --pm-sid <PM full id from PPC-1> --pr <n>`, and send the round and HEAD that row recorded; on exit 6 (cap) send nothing and go to RR-6.
- **RR-3.** Right after sending, start the PPC-4 timer with this send's msg-id (the seconds are PPC-4's, never copied). A verified ack does not stop it: rerun `next-step --gate` within that wait until the verdict is recorded (plan: the run is settled; user_verified: the last requested round has the PM's row). No verdict when the timer ends, or an ack that fails `verify`, means "no answer".
## Review request: no answer and findings

Continues `## Review request` (RR-1 to RR-3).

- **RR-4.** On the first "no answer", resend the same run or round once through PPC-3 (no new request row) and restart the timer with the new msg-id. On a second "no answer", send nothing more and ask the user (dialog: `skills/_shared/pm-review-dialogs.md`):
  - re-request the PM: plan runs `next-step --gate --audit-route pm`; user_verified goes back to RR-2 as a new round;
  - conventional audit: the user runs `echo "<<WORKFLOW_PM_REVIEW_ACCEPTED: <intent|outline|detail|PR#<n>> <reason>>>"`; it counts as a new run or round.
  - When the gate hint returns ask, ask the same choices, picking the PM by `--audit-route pm:<tag>` from the hint's `pms`. Never fall back automatically.
- **RR-5.** The PM reviews against `skills/_shared/pm-supervisor-duties.md` by trigger: plan confirmation uses `### Before plan confirmation sentinel`; user_verified uses `### Before user verification`. The PM's peer-ack names the heading it applied; a heading other than the trigger's is handled as an RR-4 resend.
- **RR-6.** On the PM's NOT_OK or AUTO_EXTEND for user_verified, fix, commit, and request a new round from RR-2. When the RR-2 request row is refused at the cap, ask the user (dialog: `skills/_shared/pm-review-dialogs.md`) showing the last findings, with only two choices: the conventional audit (`WORKFLOW_PM_REVIEW_ACCEPTED: PR#<n>`) or stop and rethink the approach.
