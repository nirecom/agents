# PM Contact Before PR Creation

Procedure for `/commit-push` CP-1b: tell the assigned PM session before CP-2 creates the PR.
Design and rationale: `docs/architecture/cross-session-messaging.md` §7; header, ack and exit codes: §4 and §6 there.
ListAgents, SendMessage and AskUserQuestion are model tools, so these steps stay in the prompt rather than a CLI.

## Recording the PM

- On receiving a `[peer-msg v1]` header with `role=pm`, write its `from-session` and `pm-issues` under `Facts to carry over` in session-progress.md, so they survive compaction.

## Skip conditions

- Run `node "$AGENTS_MAIN_ROOT/bin/workflow/pr-state"` first; on `PR_STATE=OPEN` skip this procedure (the PR and the contact already happened).
- Never skip because of `--wip`: a `--wip` run can still create the PR.

## PPC-1. Decide whether a PM is assigned

- Treat the PM as assigned only when this session chain received a `role=pm` `[peer-msg v1]` (the recorded facts above).
- With no such message, skip the rest of this procedure and continue to CP-2.

## PPC-2. Confirm the PM is in ListAgents

- Run ListAgents and write its output to a file under the session scratchpad with the Write tool.
- Count the PM as present only when one entry's name matches `PM_NAME_PREFIX_RE`, contains the first number of the recorded `pm-issues`, and ends with the suffix equal to the first 8 characters of the recorded `from-session`.
- When no entry qualifies, including a matching name with a different suffix, stop and AskUserQuestion: the PM may not have been started again by hand.

## PPC-3. Send

- Run `node "$AGENTS_MAIN_ROOT/bin/peer-msg" header --agents-file <list file>` (no `--role`: this session is not the PM) and keep its `msg-id`.
- Run `node "$AGENTS_MAIN_ROOT/bin/find-peer" --session <PM full id> --agents-file <list file>` and SendMessage to its `DESTINATION`, with the header as the first line and the PR summary after it.
- On a non-zero exit from either CLI, stop and report its `REASON` to the user; never send to a guessed destination.

## PPC-4. Wait for the ack

- Emit `<<WORKFLOW_NEXT_STEP_PAUSE: waiting for PM ack before PR creation>>`.
- Start `node "$AGENTS_MAIN_ROOT/bin/peer-msg" timer --msg-id <msg-id> --seconds 600` in the background.
- When a `[peer-ack v1]` arrives, write it to a file and run `node "$AGENTS_MAIN_ROOT/bin/peer-msg" verify --msg-id <msg-id> --expect-session <PM full id> --ack-file <ack file>`.
- On exit 0, emit `<<WORKFLOW_NEXT_STEP_RESUME: PM ack received>>` and continue to CP-2.
- When the timer ends first or `verify` exits 3 or 4, emit the RESUME sentinel and AskUserQuestion.
- Never resend automatically; this procedure adds no gate.
