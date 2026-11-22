# Send Notifications to the Issues' PM

Procedure that sends this session's recorded notification points (`bin/pm-notify record`) to the PM that owns each issue.
Design, the caller table and the PM lock: `docs/architecture/cross-session-messaging.md` §8.
ListAgents and SendMessage are model tools, so this loop stays in the prompt; every decision is the CLI's.
Fail-open: no step here blocks the workflow; on any non-zero exit, settle as below and go on.

## PN-1. Take the next notification

- Run `node "$AGENTS_MAIN_ROOT/bin/pm-notify" next`.
- No output → the procedure is done; return to the caller.
- A `SEND` line → keep its `ID`, `SESSION`, `ISSUE` and `POINT` and continue.

## PN-2. Send

- Run ListAgents and write its output to a file under the session scratchpad with the Write tool.
- Run `node "$AGENTS_MAIN_ROOT/bin/peer-msg" header --agents-file <list file>` (no `--role`) and keep its `msg-id`.
- Run `node "$AGENTS_MAIN_ROOT/bin/find-peer" --session <SESSION> --agents-file <list file>`.
- On a non-zero exit from `find-peer`, run `pm-notify settle --id <ID> --result offline` and go back to PN-1.
- SendMessage to its `DESTINATION`: the header as the first line, then one line `<POINT> <ISSUE>` with a one-sentence summary.

## PN-3. Wait for the ack and settle

- Emit `<<WORKFLOW_NEXT_STEP_PAUSE: waiting for PM ack of a notification>>`.
- Start `node "$AGENTS_MAIN_ROOT/bin/peer-msg" timer --msg-id <msg-id> --seconds 60` in the background.
- When a `[peer-ack v1]` arrives, write it to a file and run `node "$AGENTS_MAIN_ROOT/bin/peer-msg" verify --msg-id <msg-id> --expect-session <SESSION> --ack-file <ack file>`.
- Emit `<<WORKFLOW_NEXT_STEP_RESUME: PM ack wait ended>>`.
- `verify` exit 0 → `pm-notify settle --id <ID> --result ack`; the timer ended first or `verify` exited 3 or 4 → `--result timeout`.
- Go back to PN-1; never resend a settled notification.
