<!--
Cleanup cascade spec for worktree-end Steps WE-15..WE-22.
This file is a documentation spec, not an executable script: the orchestrator
Reads it and issues each git/gh/node operation one at a time (auditability +
permission dialogs). It is the canonical SSOT for what those operations are.
Read it (do not `bash` it) — same Read-as-spec pattern as skills/_shared/*.md.
-->

## WE-15 — git worktree remove
`git -C <main> worktree remove <path>` (never `--force`).

## WE-16 — On WE-15 failure (conditional)
If WE-15 (git worktree remove) exits non-zero (EPERM, busy, not-empty, any error): print stderr warning that /sweep-worktrees will reclaim automatically; skip WE-18 (orphan-dir cleanup) and WE-19 (branch -D); proceed to WE-20. (WE-18 skipped: dir occupied — self-resolves at next sweep. WE-19 skipped: git cascade rule blocks `branch -D` while worktree registered.)

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
Note: `isAllowedMainWorktreeCleanup` accepts `WORKTREE_END_SKILL=1 git -C <main> stash <push|pop|drop>` shapes — single command, no `&&`-chaining.

## WE-21 — Compose doc-append
Main worktree; only when NOTES_BACKUP_PATH is non-empty. Single canonical writer of both docs/history.md and CHANGELOG.md from WORKTREE_NOTES.md ## History Notes / ## Changelog Notes bullets (Approach C, #690). Phase 2 of issue-close no longer writes history.md.
Parse `closes_issues` from `<PLANS_DIR>/<session-id>-intent.md` → `CLOSES_ISSUES_COUNT` (0 when empty/missing). When non-empty, one bullet per closed issue expected in ## History Notes; CLI fail-fasts when bullets absent.
MERGE_SHA from env JSON written by WE-10..WE-12 (gh pr view --json mergeCommit — survives main-worktree env reset).
Delegate to doc-append-worker:
`Agent({ subagent_type: "doc-append-worker", prompt: JSON.stringify({ mode: "compose", notes_path: NOTES_BACKUP_PATH, branch: BRANCH, pr_number: PR_NUMBER, merge_commit: MERGE_SHA, pr_title: PR_TITLE, closes_issues_count: CLOSES_ISSUES_COUNT, cwd: MAIN_ROOT, agents_config_dir: AGENTS_CONFIG_DIR, artifact_dir: PLANS_DIR }) })`
On `failed` status: surface `artifact_path`; WE-22 still runs. Recovery: `bash "$AGENTS_CONFIG_DIR/bin/compose-doc-append-entry" --notes <path> --branch <b> --pr <N> --closes-issues-count <K> ...` — CLI writes via GitHub Contents/Git Data API (#672), no local git push required. CLI idempotency (per-PR markers in ~/.workflow-plans/markers/) prevents duplicates on retry.

Sibling repo fanout: parse `SIBLING_REPOS_JSON` from the env JSON (field added by capture-env.sh). For each entry where `pr_number` and `merge_sha` are non-empty, invoke doc-append-worker once with `cwd: entry.worktree_path` so compose-doc-append-entry resolves `docs/history.md` relative to that repo root — all other fields (`notes_path`, `branch`, `pr_title`, `closes_issues_count`, `agents_config_dir`, `artifact_dir`) are shared from the session. Skip entries where `pr_number` or `merge_sha` is empty (capture-env.sh already emitted WARN). On `failed` status for any sibling: log the `artifact_path` and continue to the next sibling; WE-22 still runs.

## WE-22 — Verify cleanup
`git -C <main> worktree list` — confirm no stale entries.
