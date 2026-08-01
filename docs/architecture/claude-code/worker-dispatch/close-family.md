# Worker dispatch — the issue-close family

What/Why for the two close-family workers, `issue-close-stage` (Phase 1) and
`issue-close-finalize` (Phase 2). Migrated here from the retired LLM subagent
prompts in `agents/` when #1673 replaced them with deterministic dispatcher
modules; the prompts were the only place the state contract was written down, so
the contract moved rather than disappeared.

Operational procedure lives in `skills/issue-close-{stage,finalize}/SKILL.md`.
Field types and defaults live in `hooks/lib/worker-dispatch-registry.js` (SSOT).
This file explains the shape and the reasons.

## Why finalize is multi-pass and stage is not

Phase 1 is one chain of shell steps with a single verdict. Phase 2 contains a
loop (`ICF-D..ICF-G`) whose every iteration needs an LLM judgement and, sometimes, a
user confirmation — neither of which a dispatched process can produce. So the
loop stays in the calling main context and the worker advances exactly one pass
per dispatch:

    initial ──▶ loop_step ──▶ loop_step ──▶ … ──▶ finalize_terminal

The dispatcher is a fresh process each time and holds no memory between passes.
The durable state file is the only thing connecting them.

## Phase transitions

| pass | payload `phase` | script | worker status |
|---|---|---|---|
| triage + PR/SHA resolution | `initial` | `run-initial.sh` | `init_done` \| `failed` |
| one G.5 loop step | `loop_step` | `run-loop-step.js` | `init_done` \| `awaiting_recursion` \| `terminal` \| `failed` |
| Steps ICF-H/I/J/K | `finalize_terminal` | `run-finalize-terminal.sh` | `complete` \| `failed` |

`awaiting_recursion` is the one status that hands control back to the caller for
a nested `/issue-close-finalize <parent>` run; the caller marks
`g5_history[-1].recursion_completed` and dispatches again with
`g5_decision=recurse_done`.

Regulatory invariants, now structural rather than advisory:

- **No recursion in the worker.** A worker that recursed would make the state
  file unobservable between iterations and put an unbounded chain of `gh` calls
  behind a single approval.
- **No `AskUserQuestion`.** The decision arrives as the typed `g5_decision`
  field: `accept | decline | llm_declined | recurse_done`, and nothing else.
- **No workflow sentinel on stdout.** `bin/worker-dispatch/emit.js` is the only
  writer to stdout and redacts sentinel-shaped bytes regardless of what a child
  printed.
- **Never evaluate issue text.** Child stdout is parsed as `KEY=VALUE` bytes —
  split at the first `=`, first key wins. Issue titles and bodies routinely
  contain `$(...)`, backticks and quotes; here they are inert characters. The
  retired prompt fed the same stream to `eval`, which is the defect this
  replacement closes.
- **`g5_3a_completed` is an idempotency guard.** It stops the parent-close
  proposal comment from being posted twice when a pass is retried. It is written
  by `run-loop-step.js`, validated on every read, and never cleared.
- **`ISSUE_CLOSE_SKILL` is never set by a worker.** `run-finalize-terminal.sh`
  exports it around its own two `gh` calls. Setting it at worker level would
  extend the `enforce-issue-close.js` bypass to every child of every phase.

## State file

Path: `<PLANS_DIR>/<session-id>-finalize-state-<rootN>.json`, written
tmp → rename so a reader never observes a half-written file.

```json
{
  "schema_version": 3,
  "root_issue_number": 1673,
  "current_issue_number": 1673,
  "issue_repo": "owner/repo",
  "owner_repo": "owner/repo",
  "agents_config_dir": "<resolved ACD>",
  "main_worktree_path": "<resolved main-root>",
  "merge_commit": "<40-hex or empty>",
  "phase": "init_done",
  "triage_action": "resume_e",
  "g5_loop_iteration": 0,
  "g5_history": [
    {
      "iteration": 0,
      "issue_number": "1673",
      "proposal_status": "ok",
      "proposal_parent": 1600,
      "user_decision": null,
      "g5_3a_completed": false,
      "recursion_completed": false
    }
  ],
  "proposal_counters": { "accepted": 0, "declined": 0, "skipped": 0 }
}
```

`issue_repo` is omitted for current-repo issues. When
`triage_action = meta_pending_subs` the whole `g5_history` field is omitted: a
meta parent with open sub-issues never enters the G.5 loop, and seeding an empty
array would make "the loop ran and produced nothing" indistinguishable from "the
loop never applied".

The seed entry's `iteration` is `0`, matching `g5_loop_iteration`;
`run-loop-step.js` increments the counter first and stamps each new entry with
the incremented value, so entry N always carries iteration N.

## D3 — the state file is untrusted input

The state file is durable, world-writable in the sense that anything running as
the user can edit it, and read by a fresh process that has no memory of writing
it. So it gets exactly the treatment the payload gets: the same
`bin/worker-dispatch/capability.js` `checkField` types, the same fail-closed
posture, and rejection of unknown keys in both directions. Any single failure
refuses the pass **before any child process is spawned**.

| field | type | constraint |
|---|---|---|
| `schema_version` | int | `=== 3` only |
| `root_issue_number` | int | min 1; rebind target |
| `current_issue_number` | int | min 1 |
| `owner_repo` | `owner-repo` | rebind target |
| `issue_repo` | `repo-ref` | optional |
| `agents_config_dir` | `anchor-acd` | must equal the resolved ACD |
| `main_worktree_path` | `anchor-main-root` | must equal the resolved main-root |
| `phase` | enum | `init_done` \| `awaiting_recursion` \| `terminal` |
| `triage_action` | closed set | `resume_e` \| `resume_h` \| `resume_j` \| `auto_close_path` \| `admin_close_path` \| `meta_pending_subs`, or `^stuck_[a-z0-9_]{1,32}$` |
| `merge_commit` | text, max 64 | `^[0-9a-f]{0,40}$` |
| `g5_loop_iteration` | int | 0..1000 |
| `g5_history` | array | max 64 items; optional |
| `proposal_counters` | object | exactly `accepted`/`declined`/`skipped`, each int ≥ 0 |

`g5_history[]` element keys are exhaustive — all seven required, nothing else
tolerated:

| key | type |
|---|---|
| `iteration` | int 0..1000 |
| `issue_number` | positive int, or its decimal string |
| `proposal_status` | enum `ok` \| `skipped` \| `none` |
| `proposal_parent` | positive int, or `null` |
| `user_decision` | enum `accept` \| `decline` \| `llm_declined` \| `skipped`, or `null` |
| `g5_3a_completed` | bool |
| `recursion_completed` | bool |

Unknown keys are rejected at both levels. An attacker who can add a key can
otherwise stage data for a future reader of this file.

## Session rebinding

The `state_file_path` **basename** contract
(`<sid>-finalize-state-<rootN>.json`) is enforced at payload-validation time by
the `state-file-for-session` capability type. That proves the name looks right
for this session; it does not prove the file was produced by it.

So `phase=initial` also writes a binding record beside the state file:

    <PLANS_DIR>/<session-id>-finalize-binding-<rootN>.json

with exactly five load-bearing fields — `session_id`, `root_issue_number`,
`owner_repo`, `main_worktree_path`, `state_file_path` (plus a `created_at`
timestamp that is metadata only). `loop_step` and `finalize_terminal` require a
**3-way match** across payload, state file and binding record on all five;
a missing binding record on a non-initial pass is a refusal, not a warning.
Any one of the three files alone is forgeable by whoever can write it; agreement
between all three is not.

Path fields are compared with `anchor.samePath`, never `===`. Callers
legitimately hand the dispatcher `/c/git/…` (MSYS), `C:/git/…` and `C:\git\…`
forms of the same file; a string compare would reject the honest case while
being no stronger against the dishonest one.

## Cross-repo mix-up detection

`run-initial.sh` resolves the owning repository from the issue itself and echoes
it as `OWNER_REPO`. When that disagrees with `payload.owner_repo`, the two sides
are talking about different issues, and the pass fails **without writing the
state file or the binding record** — a state file carrying the wrong
`owner_repo` would propagate the mistake into every subsequent pass.

## Environment resolution

Every child's extra environment is built from the trust anchors (ACD,
MAIN_ROOT), never read from `process.env`. `envPassthrough` in the registry
describes what *may* reach a child, not what *should*; relying on inheritance
would make a child's behaviour depend on the ambient environment of whoever
launched the session.

| phase | `extraEnv` | cwd |
|---|---|---|
| `initial` | `FINALIZE_SCRIPTS_DIR`, `MAIN_WORKTREE_PATH` | `main_worktree_path` |
| `loop_step` | `FINALIZE_SCRIPTS_DIR` | main-root |
| `finalize_terminal` | *(none)* | main-root |

`AGENTS_CONFIG_DIR` is absent from every row on purpose:
`bin/worker-dispatch/spawn.js` sets it itself from the ACD anchor, and the child
env allowlist deliberately refuses it as a caller-supplied value.

## Phase 1 (`issue-close-stage`) for contrast

One child, always: `bash run-stage-chain.sh <issue_number> <owner_repo>` with
cwd = the linked worktree. Status vocabulary is exactly
`phase1_done | blocked_sub_issue | error`, because the calling skill branches on
those and nothing else; an unrecognized token becomes `error` rather than being
passed through, so "not blocked" can never be read as "done". The worker sets no
child environment at all — the chain script exports its own hook-bypass var
around the two `gh` calls that need it.

`issue_repo` is accepted and echoed for the caller's records but is NOT
forwarded to the chain, which targets the current repo's PR and worktree.
Cross-repo Phase 1 is future scope; forwarding it silently would point Steps
D/F/G at the wrong repository.
