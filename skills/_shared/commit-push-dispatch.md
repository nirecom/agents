# Commit-Push Dispatch — Shared Procedure

Staging plus the `commit-push` worker dispatch, shared by `/commit-push` (CP-1, CP-2) and `/deliver` (DL-4).
The caller names its handoff step as `<STEP>`: `push_branch` for `/commit-push`, `deliver` for `/deliver`.

## Stage

Stage each file you intend to commit explicitly with `git add`.
Run `bash "$AGENTS_MAIN_ROOT/bin/check-unstaged-tracked.sh"` from the worktree root.
rc=1 → it prints the unstaged tracked files; `git add` them, `git stash push -u -- <file>`, or pass `--wip` (`git -c workflow.wip=1 commit`).
rc=2/3 → surface stderr and abort.
Skip this check when a WORKFLOW_OFF or WORKTREE_OFF session marker is active (parity with the workflow-gate.js bypass), and set `wip_mode: true` in the payload so the worker skips its own staging verification.
Exclude the `settings.json` `model` and `effort` fields from the commit — the system auto-updates them.

## Dispatch

Dispatch to the `commit-push` worker per `skills/_shared/worker-dispatch.md`.
Sibling pre-check (non-blocking): `bash "$AGENTS_MAIN_ROOT/bin/check-sibling-uncommitted.sh"` — it warns when a sibling worktree in `## SiblingWorktrees` has uncommitted or unpushed work.
Payload keys: `commit_message`, `branch`, `closes_issues`, `pr_body_template`, `wip_mode`, `enforce_worktree`, `script_checkout_root`, `artifact_dir` (= `PLANS_DIR`), `worktree_path` (= `git rev-parse --show-toplevel`), `session_id`.
Pass `closes_issues` as the `hooks/lib/parse-closes-issues.js` records verbatim (`{number, repo?}` objects) — never flatten them to bare numbers.
Resolve `PLANS_DIR` and `ENFORCE_WORKTREE` before dispatching.
The worker skips staging verification only when `wip_mode: true` — `--wip`, or a WORKFLOW_OFF / WORKTREE_OFF session marker.

## Outcomes

Record each outcome per `skills/_shared/handoff-record.md`: blocked → `node "$AGENTS_MAIN_ROOT/bin/workflow/handoff-append" --class D --step <STEP> --key commit-push:blocked`; landed → `--class E --step <STEP> --key commit-push:pushed`.
On `branch_mismatch`: nothing was committed; re-derive `branch` from `git rev-parse --abbrev-ref HEAD` in that worktree and re-run — never re-dispatch the same value. Record blocked.
On `staging_incomplete` or `staging_check_failed`: surface summary + artifact_path, record blocked, and stop.
On `gate_blocked`: surface the summary verbatim, record blocked, complete the workflow step it names, and re-run the caller. Never retry by another route.
On `push_failed` or `conflict`: surface summary + artifact_path, record blocked, and stop.
On `bootstrap_pending` (the remote has no default branch): nothing was pushed; record blocked; the caller's own step decides what follows.
On `pushed` (no PR — direct path or a non-GitHub/GitLab remote): report the branch and record landed.
On `pr_created` or `pr_reused`: extract the PR URL from the summary and record landed.
On `up_to_date` (nothing staged, nothing unpushed): treat as success — report it and record landed.
