#!/bin/bash
# Cleanup cascade for worktree-end Steps WE-14..WE-21.
# This script is documentation only — emits the spec the orchestrator follows.
# The actual git/gh/node operations are issued by the orchestrator one at a
# time (auditability + permission dialogs); this file is the canonical SSOT
# for what those operations are.
set -euo pipefail
cat <<'TEMPLATE'
## WE-14 — git worktree remove
`WORKTREE_END_SKILL=1 git -C <main> worktree remove <path>` (never `--force`).

## WE-15 — On WE-14 failure (conditional)
If WE-14 (git worktree remove) exits non-zero (EPERM, busy, not-empty, any error): print stderr warning that /sweep-worktrees will reclaim automatically; skip WE-17 (orphan-dir cleanup) and WE-18 (branch -D); proceed to WE-19. (WE-17 skipped: dir occupied — self-resolves at next sweep. WE-18 skipped: git cascade rule blocks `branch -D` while worktree registered.)

## WE-16 — git worktree prune
`WORKTREE_END_SKILL=1 git -C <main> worktree prune`

## WE-17 — Orphan-dir cleanup
`node "$AGENTS_CONFIG_DIR/hooks/cleanup-orphan-dir.js" "<WORKTREE_BASE_DIR>/<task-name>"`. If it refuses with "not empty", re-run with `--force-if-not-registered` (requires WE-8 inventory complete — issue #322).

## WE-18 — Delete branch
`WORKTREE_END_SKILL=1 git -C <main> branch -D <branch>` — `-D` required because squash-merge produces a new commit not recognised by `-d`'s fully-merged check. The inline `WORKTREE_END_SKILL=1` is the authorization token for `enforce-worktree.js`.

## WE-19 — Fetch + pull
`git -C <main> fetch --prune origin`
`git -C <main> pull --ff-only`
Pre-pull stash (if pull --ff-only blocked by pre-existing uncommitted changes): `WORKTREE_END_SKILL=1 git -C <main> stash push`, then `git -C <main> pull --ff-only`, then `WORKTREE_END_SKILL=1 git -C <main> stash pop`.

## WE-20 — Compose doc-append
Main worktree; only when NOTES_BACKUP_PATH is non-empty. Single canonical writer of both docs/history.md and CHANGELOG.md from WORKTREE_NOTES.md ## History Notes / ## Changelog Notes bullets (Approach C, #690). Phase 2 of issue-close no longer writes history.md.
Parse `closes_issues` from `<PLANS_DIR>/<session-id>-intent.md` → `CLOSES_ISSUES_COUNT` (0 when empty/missing). When non-empty, one bullet per closed issue expected in ## History Notes; CLI fail-fasts when bullets absent.
MERGE_SHA from env JSON written by WE-9..WE-11 (gh pr view --json mergeCommit — survives main-worktree env reset).
Delegate to doc-append-worker:
`Agent({ subagent_type: "doc-append-worker", prompt: JSON.stringify({ mode: "compose", notes_path: NOTES_BACKUP_PATH, branch: BRANCH, pr_number: PR_NUMBER, merge_commit: MERGE_SHA, pr_title: PR_TITLE, closes_issues_count: CLOSES_ISSUES_COUNT, cwd: MAIN_ROOT, agents_config_dir: AGENTS_CONFIG_DIR, artifact_dir: PLANS_DIR }) })`
On `failed` status: surface `artifact_path`; WE-21 still runs. Recovery: `bash "$AGENTS_CONFIG_DIR/bin/compose-doc-append-entry" --notes <path> --branch <b> --pr <N> --closes-issues-count <K> ...` — CLI writes via GitHub Contents/Git Data API (#672), no local git push required. CLI idempotency (per-PR markers in ~/.workflow-plans/markers/) prevents duplicates on retry.

## WE-21 — Verify cleanup
`git -C <main> worktree list` — confirm no stale entries.
TEMPLATE
