<!--
Cleanup cascade spec for worktree-end: the WE-15..WE-22 cascade plus the two
pre-steps (WE-14b, WE-14c) and the closing WE-22a that bracket it.
This file is a documentation spec, not an executable script: the orchestrator
Reads it and issues each git/gh/node operation one at a time (auditability +
permission dialogs). It is the canonical SSOT for what those operations are.
Read it (do not `bash` it) — same Read-as-spec pattern as skills/_shared/*.md.
`<main>`, `<path>`, `<sid>` and the like are placeholders the orchestrator
substitutes at issue time; a shell variable would not survive across separate
Bash calls.
-->

## WE-14b — Create cleanup-active marker
`node "$AGENTS_CONFIG_DIR/hooks/lib/worktree-cleanup-marker.js" create <sid>`
Run immediately before WE-15 — marks the WE-15..WE-22 window active so the supervisor OFF-block message adapts to real cleanup. Non-fatal on failure (fail-open: no marker → generic message). `<sid>` is the WE-12-resolved session id; empty falls back to CLAUDE_SESSION_ID.

## WE-14c — Release the CodeGraph index lock
`node "$AGENTS_CONFIG_DIR/bin/codegraph-lifecycle.js" stop --path <path>`
Run immediately before WE-15 — the daemon holds the index DB open, and on Windows that file lock makes WE-15 fail with EPERM. Idempotent and always exits 0, so a stderr warning is informational; it kills a process only when that process's own argv matches `<path>` exactly. Proceed to WE-15 in every outcome.

## WE-15 — git worktree remove
`git -C <main> worktree remove <path>` (never `--force`). Try once only — do not retry, and do NOT emit WORKTREE_OFF; on failure follow WE-16.

## WE-16 — On WE-15 failure (conditional)
If WE-15 (git worktree remove) exits non-zero (EPERM, busy, not-empty, any error): print stderr warning that /sweep-worktrees will reclaim automatically; skip WE-18 (orphan-dir cleanup) and WE-19 (branch -D); proceed to WE-20. (WE-18 skipped: dir occupied — self-resolves at next sweep. WE-19 skipped: git cascade rule blocks `branch -D` while worktree registered.) Never emit WORKTREE_OFF and never use `--force` to force removal — /sweep-worktrees salvages the leftover worktree on its next run.

## WE-17 — git worktree prune
`git -C <main> worktree prune`

## WE-18 — Orphan-dir cleanup
`node "$AGENTS_CONFIG_DIR/hooks/cleanup-orphan-dir.js" "<WORKTREE_BASE_DIR>/<task-name>"`. If it refuses with "not empty", re-run with `--force-if-not-registered` (requires WE-9 inventory complete — issue #322).

## WE-19 — Delete branch
`WORKTREE_END_SKILL=1 git -C <main> branch -D <branch>` — `-D` required because squash-merge produces a new commit not recognised by `-d`'s fully-merged check. The inline `WORKTREE_END_SKILL=1` is the authorization token for `enforce-worktree.js`.

## WE-20 — Fetch + pull
`git -C <main> fetch --prune origin`
`git -C <main> pull --ff-only`
Pre-pull stash (if pull --ff-only blocked by pre-existing uncommitted changes): `WORKTREE_END_SKILL=1 git -C <main> stash push`, then `git -C <main> pull --ff-only`, then `WORKTREE_END_SKILL=1 git -C <main> stash pop`.
Note: `isAllowedMainWorktreeCleanup` accepts `WORKTREE_END_SKILL=1 git -C <main> stash push|pop|drop` shapes — single command, no `&&`-chaining; skill-prefixed stash has no linked-worktree count upper bound (#1024).

## WE-21 — Compose doc-append
Main worktree; only when NOTES_BACKUP_PATH is non-empty. Single canonical writer of both docs/history.md and CHANGELOG.md from WORKTREE_NOTES.md ## History Notes / ## Changelog Notes bullets (Approach C, #690). Phase 2 of issue-close no longer writes history.md.
Parse `closes_issues` from `<PLANS_DIR>/<session-id>-intent.md` → `CLOSES_ISSUES_COUNT` (0 when empty/missing). When non-empty, one bullet per closed issue expected in ## History Notes; CLI fail-fasts when bullets absent.
MERGE_SHA from env JSON written by WE-10..WE-12 (gh pr view --json mergeCommit — survives main-worktree env reset).
Dispatch the `doc-append` worker per `skills/_shared/worker-dispatch.md`. Payload: `mode: "compose"`, `notes_path: NOTES_BACKUP_PATH`, `branch`, `pr_number`, `merge_commit: MERGE_SHA`, `pr_title`, `closes_issues_count: CLOSES_ISSUES_COUNT`, `cwd: MAIN_ROOT`, `artifact_dir: PLANS_DIR`.
On `failed` status: surface `summary` + `artifact_path`; WE-22 still runs. Recovery: `bash "$AGENTS_CONFIG_DIR/bin/compose-doc-append-entry" --notes <path> --branch <b> --pr <N> --closes-issues-count <K> ...` — CLI writes via GitHub Contents/Git Data API (#672), no local git push required. CLI idempotency (per-PR markers in ~/.workflow-plans/markers/) prevents duplicates on retry.

Sibling repo fanout: parse `SIBLING_REPOS_JSON` from the env JSON (field added by capture-env.sh). One dispatch per entry where `pr_number` and `merge_sha` are non-empty — re-run WD-1 with `entry.worktree_path` so `<MAIN_ROOT>` is that repo's own main worktree, and set `cwd: entry.worktree_path` so compose-doc-append-entry resolves `docs/history.md` relative to that repo root. All other fields (`notes_path`, `branch`, `pr_title`, `closes_issues_count`, `artifact_dir`) are shared from the session; give each sibling its own payload sequence suffix. Skip entries where `pr_number` or `merge_sha` is empty (capture-env.sh already emitted WARN). On `failed` status for any sibling: log `summary` + `artifact_path` and continue to the next sibling; WE-22 still runs.

## WE-22 — Verify cleanup
`git -C <main> worktree list` — confirm no stale entries.

## WE-22a — Delete cleanup-active marker
`node "$AGENTS_CONFIG_DIR/hooks/lib/worktree-cleanup-marker.js" delete <sid>`
Run after WE-22 completes. Idempotent (already-absent is success); `<sid>` is the same value as WE-14b. This closes the cleanup window, so isWorktreeEndEnv() returns false from here on.
