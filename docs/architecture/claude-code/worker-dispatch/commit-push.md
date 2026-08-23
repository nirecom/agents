# Worker dispatch — the commit-push worker

What/Why for `bin/worker-dispatch/workers/commit-push.js` and its
entrypoint-private modules under `bin/worker-dispatch/workers/commit-push/`.
The Stage 3 worker that replaced `agents/commit-push-worker.md` (#1673).

Operational procedure lives in `skills/commit-push/SKILL.md`. Field types and
defaults live in `hooks/lib/worker-dispatch-registry.js` (SSOT). The generic
child-process contract (`envScope`, `input`, anchors) lives in
[spawn.md](spawn.md). This file explains the worker's own shape and reasons.

## Module map

| module | owns |
|---|---|
| `commit-push.js` | dispatch + re-export only |
| `commit-push/procedure.js` | steps 0-6 and 8, the run() spine, the artifact log |
| `commit-push/gate.js` | the D1 gate seam, gate env resolution, child-process helpers |
| `commit-push/push.js` | step 7 — push attempts and the rebase ladder |
| `commit-push/pr.js` | step 9 — the idempotent PR step and the outbound scan |

## The ten steps

The step numbers are kept from the agent prompt this worker replaces, so a
reader of either document is looking at the same procedure:

| # | action | why it is here |
|---|---|---|
| 0 | `git rev-parse --abbrev-ref HEAD` | `payload.branch` IS the checked-out branch |
| 1 | `git diff --cached --stat` | staged changes exist at all |
| 2 | `bin/check-unstaged-tracked.sh` | Gate 3 staging verification (skipped in `wip_mode`) |
| 3 | D1-a: workflow-gate before commit | see D1 below |
| 4 | `git commit` | `--no-verify` is prohibited; `hooks/pre-commit` still runs |
| 5 | `bin/probe-remote-bootstrap.sh` | empty remote → defer to `/worktree-end` |
| 6 | D1-b: workflow-gate before push | see D1 below |
| 7 | `git push`, 3 attempts, rebase ladder | never a force flag |
| 8 | `enforce_worktree=off` / non-GitHub remote | → no PR |
| 9 | `gh pr view` (reuse) or `gh pr create` | idempotent PR step |
| 10 | write the combined child output to the artifact log | best-effort |

Step 0 fails closed. Nothing downstream re-derives the branch: the upstream
probe, the push refspec, the protected-branch test and `gh pr create --head` all
take the payload's word for it. A stale or crafted payload would otherwise
commit and push THIS worktree's staged changes under another branch's name, or
claim a safe name while the checkout is on `main` and walk past
`isProtectedBranch()` entirely. A probe that cannot answer is a mismatch, not a
pass — this runs before the first mutation, so failing closed costs nothing.

Step 10 is best-effort in the other direction: a refused log write must not turn
a completed push into a reported failure. `fsguard` routes the bytes through
`redactSentinels`.

## D1 — why the gate runs inside the worker

Moving `git commit` / `git push` out of the Bash tool also moves them out of
PreToolUse, where `hooks/workflow-gate.js` used to see them. Two guards go with
it: the commit-completion gate (`run_tests` / `review_security` / docs /
`user_verification`) and the MERGE GATE, which blocks a push to a protected
branch until `user_verification` completes regardless of `ENFORCE_WORKTREE`.
`hooks/pre-commit` replaces neither.

So the real gate binary is driven as a child process twice, with a synthetic
PreToolUse payload on stdin, and the `command` string it is asked about is the
argv this worker is about to spawn — joined from that exact array, never a
hand-written approximation. The push argv is therefore decided BEFORE the gate
runs. A bare `git push` is never issued: `merge-detect.js` decides on explicit
refspecs, so the bare form can slip past the classifier.

No payload free text is ever part of that argv. The commit message reaches git
on stdin (`git commit -F -`) because the gate resolves the repository it judges
by scanning the command string — `hooks/workflow-gate/repo-resolution.js` looks
for a `git -C <path>` anywhere in it — and author-controlled text inside `-m`
could name a different repository than the one being committed to, one whose
state resolves to "approve". Keeping the message off the command line closes
that, and keeps it out of the process table.

`-c workflow.wip=1` must precede the subcommand: git ignores it afterwards, and
`workflow-gate.js` only recognizes the pre-subcommand form.

**FAIL-CLOSED.** A gate child that crashes, times out, or answers with something
that is not JSON is NOT permission. Every such degradation stops the run with
`gate_blocked`; when the push target is a protected branch the summary says so,
because that is the case where continuing would have been irreversible.
`workflow-gate.js` prints its verdict and always exits 0, so a non-zero exit
means it died before deciding — silence, not permission. Permission is exactly
one token, `approve`: `deny`, `ask`, a typo, or a decision this worker predates
are all refusals, because an allowlist of one cannot be widened by anything the
gate learns to say later.

## Gate env resolution

The six workflow env vars (`GATE_ENV_SCOPE` in `gate.js`) are resolved to
concrete values and passed EXPLICITLY through `extraEnv` — never read from
`process.env`. They are also in the entry's `envPassthrough`, which permits
silent inheritance, and an inherited `CLAUDE_WORKFLOW_DIR` points the gate
child at a different session's state, where every step reads "missing" and the
gate approves everything. That is the quiet failure this resolution exists to
prevent (Risk 3).

**Which side wins.** The four vars that name a session, a checkout, or the
worktree-enforcement mode (`WORKFLOW_PLANS_DIR`, `WORKFLOW_SESSION_ID`,
`CLAUDE_PROJECT_DIR`, `ENFORCE_WORKTREE`) come from the validated payload and
the resolved anchors ONLY — the same rule `spawn.js` applies to
`AGENTS_CONFIG_DIR`. An inherited `WORKFLOW_SESSION_ID` or `CLAUDE_PROJECT_DIR`
from a stale or poisoned parent env would otherwise out-rank the payload and
point the gate at another session's step statuses or another checkout's staged
changes — i.e. redirect the verdict away from the work actually being
committed; an inherited `ENFORCE_WORKTREE` would let a poisoned parent env
silently downgrade the gate's own enforcement mode.

The other two have no payload or anchor counterpart, so they are read from the
`.env` at the ACD anchor via `readEnvFile()`, which is pure and never consults
`process.env`. That file lives in the reviewed main checkout resolved from the
module's own realpath (`anchor.js` `resolveAcd` drops the env candidate for the
same reason), so neither value is forgeable by an inline `VAR=x node bin/...`
prefix or by a poisoned parent env. Both are decisions a gate depends on:

- `CLAUDE_WORKFLOW_DIR` names the state root the gate reads step statuses from —
  a planted directory holding a fabricated state file makes it approve.
- `DEFAULT_BRANCHES` is the protected-branch set arming both
  `isProtectedBranch()` and `merge-detect.js`'s own `getProtectedBranches()` in
  the gate child, so a list omitting main/master disarms the merge gate.

`readEnvFile` returns null when the file is missing or unreadable; that is
treated exactly like an empty map and the documented defaults apply.
`getWorkflowDir()`'s own fallback is `<HOME>/.claude/projects/workflow`, so the
default here resolves to the same directory the gate child would compute for
itself.

## Step 7 — the push retry and the rebase ladder

Three attempts, with waits before attempts 2 and 3 only. No force flag is ever
assembled — not `--force`, not `--force-with-lease`.

A non-fast-forward rejection triggers the ladder: fetch, replay this branch on
top, retry the SAME explicit push. `--autostash` keeps an unrelated dirty
worktree out of it.

**Why fetch and rebase are two calls, not one `git pull --rebase`.** The single
`pull` fused two very different operations under one env scope. The fetch half
is a network operation and genuinely needs `SSH_AUTH_SOCK`. The rebase half is a
local replay that runs repo-configured hooks (`pre-rebase`, `post-rewrite`) and
merge/smudge drivers — a code-execution surface, and one that has no use for the
signing socket. Splitting them lets the rebase run with `envScope: []`, so
branch-supplied hook code cannot reach the agent. The rebase targets
`origin/<branch>`, the same ref `pull --rebase origin <branch>` resolved to.
