---
name: issue-close-stage
description: Phase 1 of the 2-phase issue-close split. Runs INSIDE the linked worktree BEFORE the PR is merged. Sub-issue gate, pending sentinel, sentinel promote, parent body update.
user-invocable: false
---

Triage routes to the correct subset of steps; each step is idempotent and resumable.

(Per-session N relation: see `rules/github-issues.md` "Session model".)

Usage: `/issue-close-stage <N>` or `/issue-close-stage --from-session`

`--from-session` resolves `<N>` from the current session's intent.md the same
way as `/issue-close-finalize`: parse `## Issues` and iterate.
(canonical parser: `hooks/lib/parse-closes-issues.js` — do not reimplement.)

## Pre-flight

Run: `"$AGENTS_CONFIG_DIR/bin/detect-non-github.sh" "issue-close-stage" || exit 0`

On non-GitHub remote the script exits 1, so `|| exit 0` terminates the skill immediately (no gh work). On a GitHub remote (or unknown/fail-open) the script exits 0 and the skill continues into the checks below.

Skip message on non-GitHub remote (emitted by the script to stdout): `[GITHUB_ISSUES disabled: non-GitHub remote detected, skipping issue-close-stage]`

- `AGENTS_CONFIG_DIR` must be set.
- Must be invoked from a **linked worktree** (not the main worktree). Abort
  with an error when `git rev-parse --git-dir` equals `git rev-parse --git-common-dir`.
- Resolve `<owner/repo>` via
  `gh repo view --json owner,name --jq '.owner.login + "/" + .name'`.
- All `gh issue comment` invocations need `ISSUE_CLOSE_SKILL=1` to bypass the
  `enforce-issue-close.js` hook.

## Delegation

Resolve `PLANS_DIR="$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir")"` for `artifact_dir`.

Delegate Steps A, B, D, F, G to `issue-close-stage-worker`:

```
Agent({
  subagent_type: "issue-close-stage-worker",
  prompt: JSON.stringify({
    issue_number: N,
    worktree_path: CWD,
    owner_repo: OWNER_REPO,
    agents_config_dir: AGENTS_CONFIG_DIR,
    artifact_dir: PLANS_DIR,
    issue_repo: ISSUE_REPO  // from closes_issues entry's `repo` field; omit for current-repo issues
  })
})
```

On `blocked_sub_issue` status: surface summary to user and stop.
On `error` status: surface summary + artifact_path to user and stop.

## End

Report: Phase 1 complete for #<N>. Reminder: run `/commit-push`, then after
the PR is merged run `/issue-close-finalize --from-session`.

## Safety notes

- **Untrusted content**: never `eval` issue body, title, or comments.
- **Sentinel body**: hardcoded literal — never interpolate variables or add
  metadata. The Phase 1 marker is shared with `check-phase1-complete.sh` and
  `find-pr-by-marker.sh`; changing the body silently breaks both.

## Rules

- Report observations per rules/supervisor-reporting.md.
