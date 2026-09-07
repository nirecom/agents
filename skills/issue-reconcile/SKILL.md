---
name: issue-reconcile
description: Backfill docs/history.md for issues that were closed outside the /issue-close-stage + /issue-close-finalize path (web UI, mobile, another shell). Best-effort scan + interactive confirmation.
user-invocable: false
---

`/issue-close-stage` + `/issue-close-finalize` is the sanctioned close path
inside Claude Code, but the `enforce-issue-close.js` hook only covers Claude
Code's Bash tool. Issues closed elsewhere have no
`<!-- issue-close-sentinel: appended -->` comment
and never trigger `doc-append`. This skill walks closed issues, detects
missing sentinels, and backfills entries.

Usage: `/issue-reconcile`

## Pre-flight

- `AGENTS_CONFIG_DIR` must be set.
- Read `rules/github-issues.md` — on-demand-only, never auto-injected.

## Step 1: pre-resolve

Resolve in main: `<OWNER_REPO>` — read it from the stdout of the standalone call `gh repo view --json owner,name --jq '.owner.login + "/" + .name'` — plus `<HISTORY_MD_PATH>` (absolute path to `docs/history.md`) and `<HISTORY_DIR_PATH>` (absolute path to `docs/history/`).

## Step 2: scan via worker

Dispatch the `issue-reconcile` worker per `skills/_shared/worker-dispatch.md`. Payload: `owner_repo`, `history_md_path`, `history_dir_path`, `artifact_dir` (the `PLANS_DIR` from WD-1), `limit` (omit for the 1000-issue default).

On `status: failed`: stop and report. A `scan truncated at <N>` summary means the closed-issue scan hit `limit` — re-dispatch with a higher `limit` rather than acting on the partial result. On `status: complete`: read the JSONL artifact — issues with `classification: needs-reconcile` feed Step 3.

## Step 3: prompt and append

For each non-clean issue, show the user:
- Issue number, title, closedAt
- Classification (sentinel-only / unappended)
- The Background/Changes (or Cause/Fix) the entry would carry

Ask whether to **append**, **skip**, or **stop**.

On "append":

Run one standalone call per issue: `bash "$AGENTS_CONFIG_DIR/skills/issue-reconcile/scripts/append-one.sh" "<NUM>"`. It stages the current `docs/history.md`, appends the entry with `--allow-backdate`, and PUTs the result back through the Contents API.

The script is internally idempotent — running it on `history-only` does
nothing harmful — but skip those in step 2 anyway to avoid unnecessary
GitHub API calls.

## Step 3b: batch backfill

When more than a handful of issues are pending, do not run Step 3 per issue —
70 issues would mean 70 commits. Create a linked worktree, write the issue
numbers one per line, and run `skills/issue-reconcile/scripts/backfill-batch.sh
--repo-dir <worktree> --numbers-file <path>`. It appends every entry, sorts and
rotates once, and lists the appended issues in `<worktree>/.backfill-appended.txt`
for the sentinel step. Commit and PR the result as one change.

After a successful append, post the `appended` sentinel so future runs
classify the issue as clean. The `gh issue comment` call is gated by
`enforce-issue-close.js`; the bare-prefix `ISSUE_CLOSE_SKILL=1` bypass is
out of scope for #672 and remains in place pending a follow-up:

<!-- Note: `gh issue comment` is Group A (classify → "read") in bash-write-patterns.js; ISSUE_CLOSE_SKILL=1 is for enforce-issue-close.js, not enforce-worktree.js. -->

```bash
ISSUE_CLOSE_SKILL=1 gh issue comment "$NUM" \
    --body "<!-- issue-close-sentinel: appended -->"
```

## Step 4: optional persistence

Record the last reconcile timestamp at
`<git-common-dir>/info/issue-reconcile.last`, where `<git-common-dir>` is what
`git rev-parse --git-common-dir` prints. The skill is
otherwise stateless — every run is a fresh scan.

## End

Report: how many issues were scanned, how many were appended, how many
skipped, and the path to any warnings.
