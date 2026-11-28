# Cross-Session Messaging — resolving a peer and confirming delivery

How one Claude Code session finds the SendMessage destination of another session from an issue
number or a session id, and how the sender confirms the message arrived (#2668). The PM
supervisor (#2927) is the first consumer: its PM session sends instructions to each workflow
session from outside.

## 1. Why a convention, not a registry

- The accepted destination shape is decided by the Claude Code binary, not by repo code, so the
  repo derives the destination from the session id by convention and keeps no mapping table.
- The forge records are the only source: the WIP holder ([wip-signaling.md](wip-signaling.md))
  names the working session, and the origin marker (§3) names the session that filed the issue.
- The NFRs assume one user on one PC, so a registry or a resend queue would be over-built.
- Sender authenticity (spoofing) is out of scope here and belongs to #2943; this doc covers
  delivery acknowledgement only.

## 2. Session name format

`hooks/lib/session-name.js` (`composeSessionName`) owns the format; `bin/session-name` prints it
for a manual `/rename` of a workflow session.

| Kind | Name |
|---|---|
| `work` | `#A[ #B …] <title of #A> sid-xxxxxxxx` |
| `pm` | `[PM] <tag>: #A[ #B #C …] <title> sid-xxxxxxxx` |
| `pm` with no issues, or archived | `[PM] <tag>: <objective> sid-xxxxxxxx` |
| `none` | `<repo name> sid-xxxxxxxx` |

- `[ #B …]` marks optional extra issues; an issue of another repo shows as `repo#N`.
- Issue numbers come before the title because plugins and apps show only the first characters
  of a name.
- PM session: the PM tag right after `[PM]` identifies the PM. The issues are its assigned list
  from the PM state, and the title is the title of the first issue only (the titles of B, C are
  never fetched), or the `/pm-init` theme when the list is empty.
- A PM session is named by the issue-title hook alone, from its state, each time the list
  changes through `/pm-init`, `/pm-add`, `/pm-remove` or `/resume-session --from`; no PM renames
  itself by hand.
- `none` name: the repo part of the origin URL, falling back to the cwd basename.
- session-name suffix ` sid-xxxxxxxx`: a space, `sid-` and the lower-cased first 8 characters of
  the current session id, appended to every kind. It is not bracketed, because ListAgents reads a
  trailing bracket as its `[ref]` (§8, Verification (b)). A session id that is not UUID-shaped gets no session-name suffix and is
  never matched.
- The title is cleaned and cut like `cleanTitle` / `TITLE_MAX`; numbers, PM tag and session-name
  suffix are never cut.
- Matching reads the session-name suffix only, through `SESSION_NAME_SUFFIX_RE`;
  `PM_NAME_PREFIX_RE` tells a PM session apart. Both regexes live only in
  `hooks/lib/session-name.js`.
- The ListAgents ref, the 6-character bracket ListAgents appends when it shows a name, is not the
  session-name suffix; never copy it into a title.
- When you `/rename` by hand, keep the session-name suffix `bin/session-name` prints. A session
  whose session-name suffix was removed cannot be found by `find-peer` when the destination is a
  name (§5).

How and when the hook emits the name, including sessions without workflow state:
[claude-code/settings/hooks.md](claude-code/settings/hooks.md) (`user-prompt-submit-issue-title.js`).

## 3. Origin marker

- Form: one hidden HTML comment line `<!-- origin-session: <full session id> -->` at the end of
  the issue body. Neither GitHub nor GitLab renders it.
- Writer: `bin/github-issues/lib/origin-session.sh`, called by `bin/github-issues/issue-create.sh`
  (`--origin-session <sid>`, else resolved through `bin/resolve-session-id`) and by
  `clarify-commit-scope.sh` Path C. The marker is added before the outbound scan, so the scanned
  body is the posted body. Every `issue-create-dispatch.sh` verdict goes through `issue-create.sh`.
- When the id cannot be resolved (rc 2 or 3), the writer warns and creates the issue without the
  marker.
- Reader: `bin/find-peer.d/origin.js`, through the tracker descriptor's `issueBody` (GitHub
  `gh issue view --json body`, GitLab `.description`, stub `null`).
- GitLab: the writer is forge-neutral but verified with mocks only; no repo path files GitLab
  issues from a session.
- Migration scripts (`migrate-*.sh`, `open-stale-migration-issue.sh`) add no marker; they do not
  file from a session.

## 4. `find-peer` contract

- `bin/find-peer --issue <N> [--role working|origin] [--repo <slug>] [--agents-file <path>]`
- `bin/find-peer --session <sid|self> [--agents-file <path>]`

Arguments:

- `--role` defaults to `working` (the WIP holder, read with `wip-state.sh holder`). A missing
  holder is a failure; it never falls back to `origin`.
- `--session self` resolves the caller's id through `bin/resolve-session-id`.
- `--agents-file`: ListAgents is a model tool that a CLI cannot call. When the destination kind
  is `ref` or `name`, the caller writes the ListAgents output to a file and passes it.
- Paths given to the CLI are normalized with `toWindowsPath` before use.

Success prints key=value lines: `ROLE=working|origin|self`, `SESSION_ID=<full id>`,
`DESTINATION=<string for SendMessage>`, `DESTINATION_KIND=session-id|ref|name`.

Failure prints `REASON=<token>` and never returns a guessed destination:

| Exit | REASON |
|---|---|
| 2 | usage error, or `agents-list-unparsable` (a ListAgents file it cannot parse) |
| 3 | `no-holder` |
| 4 | `no-origin` |
| 5 | `not-in-list` |
| 6 | `ambiguous` |
| 7 | `forge-read-failed` |
| 8 | `agents-list-required` |

## 5. Destination branch

`DESTINATION_KIND` is decided by verification (b) alone, never by whether a title is applied.
The result is a constant in `bin/find-peer.d/destination-policy.js`, with the observed Claude
Code version in a comment.

1. SendMessage accepts a session id: `DESTINATION=<session id>`; no ListAgents file is used.
2. Otherwise, it accepts `[ref]` and the list maps `[ref]` to a session id without the name:
   return that `[ref]` from the list.
3. Otherwise, it accepts names only: resolve the actual name from the list. Only this branch
   depends on the name being applied.
4. None works: not implemented; the gap is recorded on the issue and split off.

In branch 3 only, a list entry is a candidate when its name ends with `SESSION_NAME_SUFFIX_RE` and
the 8 characters equal the first 8 of the target id. One candidate succeeds, zero is
`not-in-list`, two or more is `ambiguous`. A name without the suffix is never a candidate, even
when its title text matches. Branches 1 and 2 ignore names, so `/rename` cannot break them.

After a resume that changes the session id, the WIP holder and the name suffix may still carry
the old id; `find-peer` then fails with `not-in-list` instead of guessing, and an ack mismatch
(§6) also exposes it. The suffix only narrows the match: with v7 session ids the first 8
characters change roughly every 65 seconds, so the full-id ack is what confirms delivery.

## 6. Ack convention

`hooks/lib/peer-msg.js` is the only definition of the format; `bin/peer-msg` uses it.

- Send header, the first line of the body:
  `[peer-msg v1] from-session=<full id> msg-id=<uuid> reply-to=<destination> reply-kind=<session-id|ref|name|from> [role=pm pm-issues=#A,#B]`.
  `role` and `pm-issues` are set only when a PM sends.
- `bin/peer-msg header [--agents-file <path>] [--role pm --pm-issues <list>]` makes a msg-id and
  calls `find-peer --session self`, passing `--agents-file` through. Pass the same ListAgents file
  to the peer lookup and to `header`. When the self lookup fails with `agents-list-required` and
  verification (b) confirmed replies to `from`, the header uses `reply-kind=from`; otherwise it
  exits 8 with `REASON=agents-list-required` and nothing is sent.
- Ack, sent by the receiver to `reply-to`: `[peer-ack v1] ack-of=<msg-id> session=<receiver full id>`.
- `bin/peer-msg verify --msg-id <id> --expect-session <id> --ack-file <path>` exits 0 on a match,
  3 when no ack is found, 4 on a mismatch. On 3 or 4 nothing is resent; the caller reports it.
- `bin/peer-msg timer --msg-id <id> --seconds <n>` is the wait timer a caller runs in the
  background; it exits 0 naming the msg-id when the time is up.
- When no ack arrives, the caller decides whether to resend or report; there is no automatic resend. An idempotent resend keyed by msg-id is left to #2941 and later.
- Aligning this header with the #2593 inbox format is left to that issue; this doc only notes it.

## 7. PM contact before PR creation

The duties a PM gives its workflow sessions have one master: `## Workflow session` in [`skills/_shared/pm-supervisor-duties.md`](../../skills/_shared/pm-supervisor-duties.md).

The only path that creates a PR is `/commit-push` CP-2 (`/merge-to-main` MM-4 pushes directly and
creates none), so the contact runs there as CP-1b, a skill step rather than a hook or gate. The
procedure is [skills/_shared/pm-pre-pr-contact.md](../../skills/_shared/pm-pre-pr-contact.md).

- A session has an assigned PM only when it received a `role=pm` `[peer-msg v1]`; with none, the
  step is skipped. A PM that never contacted the issue therefore leaves it skipped; registering
  on the PM side is #2941.
- The PM is identified by the recorded `from-session` and `pm-issues`, since ListAgents shows
  names, not full ids. A PM missing from the list, or one whose suffix differs (it restarted and
  got a new id), stops the step for a user question: the PM may not have been started again by
  hand after an OS restart.
- The wait is 600 seconds: the PM is an interactive LLM session that usually answers within
  minutes even while busy with another turn, so 10 minutes does not over-wait.
- A timeout or an ack mismatch goes to the user. There is no automatic resend and no new gate.

### `pm-issues`: how it is built and checked

- `bin/peer-msg header --role pm` takes no `--pm-issues` (passing it is a usage error): it reads
  the assigned issue list of its tag's current generation, so a PM cannot announce issues it does
  not own, and a session of an older generation announces what the tag owns now, not its stale copy.
  No PM state, a renamed tag (`NEW_TAG=`), or an empty list (`REASON=no-pm-issues`) refuses with
  exit 1 and a `REASON`.
- The workflow side runs `bin/pm-notify check-header` (PPC-1). It compares the header's whole
  `pm-issues` set with `closes_issues` and with the forge owner of each issue (`OWNER_TAG=`):
  `RESULT=mismatch` (`EXTRA=` / `MISSING=`, or `REASON=owner-differs`) and `RESULT=undecidable`
  go to the user. An `owner` hit with no recorded header still counts as an assigned PM.

### Review request (#3144)

The same procedure file carries `## Review request`: the assigned PM reviews the plan at each
plan-stage confirmation and the PR before `USER_VERIFIED`, in place of the supervisor-audit subagent.

- Plan stages ride the pre-confirm audit run: the gate routes `audit-wait` to the PM and the PM
  writes the run's verdict (`supervisor-audit-ledger.md` "PM route").
- The PR review is a round of the pm-review record (`review-rounds` format `pm-review`, the
  control dir's `pm-review-review-rounds.jsonl`). Before sending, the workflow session writes a
  request row (`source=request:<PM sid>`, verdict `REQUESTED`, `run_id=pr:<n>`, the HEAD SHA as
  fingerprint); the PM answers with one row per round (`source=pm`, `OK` / `NOT_OK`, `--high`
  turning a capped `NOT_OK` into the one `AUTO_EXTEND`). Rounds stop at the cap of 2 plus one
  extension; a refused request row goes to the user.
- The user's `WORKFLOW_CONVENTIONAL_AUDIT_CHOSEN: PR#<n>` (ask-gated) writes a `source=user` row, or
  `user-pr-unconfirmed` when the forge does not answer and the last request named that PR; the
  TR5 audit then runs as before.
- `hooks/workflow-gate/user-verified-pm-review.js` passes `USER_VERIFIED` only on the PM's `OK`
  in the last requested round or the user's row, each tied to the current HEAD and PR; a forge
  that does not answer passes only the `user-pr-unconfirmed` row. A web merge emits no
  `USER_VERIFIED`, so there `/get-release-approval` GA-1 (PM review) is the only enforcement.
- The wait reuses the PPC-4 timer from the actual send; one resend, then the user decides. No
  automatic fallback to the subagent.

## 8. PM notification points

Why: the PM must learn of changes to its issues without polling each session. Each notification
point records a note in the workflow session's state (`bin/pm-notify record`; a pending note for
the same point, issue and PM is reused), and the skill loop
[skills/_shared/pm-notify.md](../../skills/_shared/pm-notify.md) sends it with the §6 header and
settles it as `ack`, `timeout` or `offline`. Every layer is fail-open: a failure never blocks the
workflow. Notes the PM could not take land in its mailbox; `pm-notify close` reports what is left.

| Point | Recorded by | Sent by |
|---|---|---|
| `start`, `multi-pm` | `/workflow-init` driver phase `pm-scan` (owner lookup, 10 s budget) and `write-context` | `/workflow-init` on `done` / `blocked` |
| `wf-meta` | `bin/workflow/set-deliverable-type --type wf-meta` | `/workflow-init` PM3 |
| `scope-change` | `next-step` gate on an approved detail scope change | `confirm-plan.md` `present-and-stop` |
| `reopen`, `split`, detach | `issue-create-dispatch.sh` (`reopen`, `bulk-sub-of`, `make-parent`) | `/issue-create` after Phase 4 |
| `merge` | `/merge-to-main` MM-3a, `/get-release-approval` GA-4 (web merge) | the same steps |
| `session-close` | `/session-close` SC-6a | SC-6a, then `pm-notify close` |

- Two or more owners among a session's issues block `/workflow-init` with `REASON=multi-pm`
  after a `multi-pm` note goes to each PM; the user reassigns with `/pm-remove` / `/pm-add`.
- On the PM side the inbox (`runInbox`) shows and empties the mailbox after each PM command and at
  session start; the forge drift check runs only at session start, within its time slice.
  The forge steps (unassigned owner lookup, drift, meta detach) run only when the home origin is
  GitHub; elsewhere `unassigned.jsonl` is left as is and no `gh` call is made.
- PM lock liveness: a lock holder counts as alive while its pid lives and its process start time
  matches `start_ms` within 2000 ms (an unreadable start time counts as alive). A live holder's
  lock is never taken, even past `PM_LOCK_STALE_MS`; the command refuses with `HOLDER_PID` and
  `HOLDER_AGE_MS` so the user can stop the holder. Serialising forge writes wins over availability.

### PM command time budget (#3152)

Why: the PM writer runs inside the `UserPromptSubmit` hook; fixed per-call gh limits added up past
the hook timeout, and a command killed by it told the user nothing.

- One budget per hook run, counted from the hook process's start
  ([hooks/pm-session/budget.js](../../hooks/pm-session/budget.js) owns the numbers): lock wait, check,
  card creation (only with enough left), field write and inbox each get a derived deadline; the title read takes what is left.
- The check is one composite query (field chains, sub-issue trees, cards); the writes are one aliased mutation per chunk.
- Failure classes ([bin/lib/forge-failure.js](../../bin/lib/forge-failure.js)): `budget-exhausted` (gh not run),
  `timeout` (gh did not answer), `spawn-failed` (gh could not start). A refusal names the class and the next action.

## 9. Verification observations

Verification (a) and (b) ran on a real session on 2026-11-09; the full note is a comment on issue #2668.

### Claude Code version

2.1.319 (VS Code extension).

### Verification (a) — title applied

The hook recorded `last_emitted`, but the title shown on screen did not change. The cause is not
identified, so the title is still renamed by hand; `find-peer` and the ack stay the primary path.

### Verification (a) — default name vs title name

ListAgents names a session by its title. A session never titled shows its default name.

### Verification (b) — accepted destination shape

Observed 2026-11-09 (Claude Code 2.1.319), with the bracketed session-name suffix of that time
(` [xxxxxxxx]`): sending the bare title `PROBE-2668 [4845aca2]` to a peer was refused as unreachable,
because the trailing bracket is read as a `[ref]`. Sending
`PROBE-2668 [4845aca2] [ba91da]` (title plus the ListAgents ref) was delivered. Addressing one's own
session that way is refused ("also addresses this session"). The destination kind is therefore `name`,
the destination is `<title> [<ref6>]`, and a session id resolves through the session-name suffix of
the title. Because a trailing bracket collides with the ListAgents `[ref]`, the suffix moved to the
unbracketed ` sid-xxxxxxxx` form (§2).

### Verification (b) — reply to `from` and ListAgents output format

A ListAgents row reads `<name> [<ref 6 hex>]  ·  <kind>  ·  <state>  ·  …`, the bracket being the
ListAgents ref; no session id is listed.
A reply addressed to an incoming message's `from` attribute arrived end to end: a peer answered a ping
with `pong`, and this session replied to that message's `from` (`uds:\\.\pipe\LOCAL\cc-msg-…`) with
no name involved (`FROM_REPLY_VERIFIED` is true). Whether the peer then read that reply is not observed.

The dump opens with the own-session line `This session is <name> [<ref6>] — <clause>`, followed by
`Peer sessions (N):` and the rows. The name is unquoted (it never starts with `"`) and may contain spaces,
brackets and the session-name suffix ` sid-xxxxxxxx`; the separator is the last ` [<ref6>] — ` (the
ListAgents ref), because the clause
holds no `[…]`. The older form `This session is "<name>" [<ref6>].` is still accepted. The real line was
captured in a PM session.
The own session appears only on that first line, never as a row, so `agents-list.js` reads it to resolve a
`--session self` lookup. A `This session is` line matching neither form is not skipped: the parse fails
with `agents-list-unparsable` (exit 2), so a format change surfaces at its cause instead of as
`not-in-list`. Only `Peer sessions (N):` is skipped as a header. A name without the session-name suffix
stays `not-in-list`; since #2941 the issue-title hook names every PM session with it (§2).

### Title reflection: minimal hook and known upstream bugs

A minimal `sessionTitle` hook changed the shown title, while the repo's real hook did not visibly do so;
the repo-side cause is still unidentified. Related open reports in anthropics/claude-code: #99335, #107722,
#104749, #104362, #104154, #108052 (closed: #48868, #86607). Because titles are not reliable, the design
never depends on the title being applied (§5).
