---
name: issue-close-stage
description: Phase 1 of the 2-phase issue-close split. Runs INSIDE the linked worktree BEFORE the PR is merged. Sub-issue gate, pending sentinel, doc-append + commit, sentinel promote, parent body update.
user-invocable: false
---

Triage routes to the correct subset of steps; each step is idempotent and resumable.

Usage: `/issue-close-stage <N>` or `/issue-close-stage --from-session`

`--from-session` resolves `<N>` from the current session's intent.md the same
way as `/issue-close-finalize`: parse `## closes_issues` and iterate.

## Pre-flight

```bash
NON_GITHUB=0
"$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote"; rc=$?
case $rc in
  0) ;;                # GitHub — proceed with gh
  1) NON_GITHUB=1 ;;   # non-GitHub — skip gh invocation
  *) ;;                # unknown (rc=2) — fail-open, keep existing behavior
esac
if [ "${NON_GITHUB:-0}" = "1" ]; then
  echo "[GITHUB_ISSUES disabled: non-GitHub remote detected, skipping issue-close-stage]"
  exit 0
fi
```

- `AGENTS_CONFIG_DIR` must be set.
- Must be invoked from a **linked worktree** (not the main worktree). Abort
  with an error when `git rev-parse --git-dir` equals `git rev-parse --git-common-dir`.
- Resolve `<owner/repo>` via
  `gh repo view --json owner,name --jq '.owner.login + "/" + .name'`.
- All `gh issue comment` invocations need `ISSUE_CLOSE_SKILL=1` to bypass the
  `enforce-issue-close.js` hook.

## Step A: triage

```bash
eval "$(bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-close-stage-triage.sh" <N>)"
# Sets STATE, SENTINEL, ACTION, NEXT_STEPS.
```

If `ACTION=phase1_done`, exit 0 silently (sentinel + history already present).
If `ACTION` is an error variant, surface stderr and exit 1.
Otherwise execute the steps in `NEXT_STEPS` (comma-separated, in order).

## Step B: sub-issue gate

```bash
bash "$AGENTS_CONFIG_DIR/bin/issue-close-gate.sh" <owner/repo> <N>
```

Non-zero → BLOCK; do not post the pending sentinel and stop.

## Step D: post `pending` sentinel (capture comment ID for Step F)

```bash
COMMENT_URL=$(ISSUE_CLOSE_SKILL=1 gh issue comment <N> \
    --body "<!-- issue-close-sentinel: pending -->" 2>/dev/null | tail -n 1)
COMMENT_ID=$(printf '%s' "$COMMENT_URL" | grep -oE '[0-9]+$')
[ -z "$COMMENT_ID" ] && { echo "Error: failed to extract comment ID from gh output" >&2; exit 1; }
```

**CRITICAL**: the body MUST be the hardcoded literal shown above.
No variable interpolation. No metadata fields added. This keeps the sentinel
safe to post on public repos.

`gh issue comment` prints the comment URL on stdout (last line). The trailing
numeric segment in the URL is the REST API comment ID needed by Step F's PATCH
call.

## Step E: idempotent doc-append + commit (with rotation handling)

```bash
ISSUE_CLOSE_SKILL=1 bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-to-history.sh" <N>
```

`doc-append` (invoked by `issue-to-history.sh`) auto-fires `doc-rotate.py`
when `docs/history.md` crosses 500 lines. Rotation can:
- Trim `docs/history.md` (deleted lines).
- Create or update `docs/history/YYYY.md` (year archive files).
- Update `docs/history/index.md` (rotation-rebuilt index).

To capture both additions and deletions across both paths, stage both with `-A`:

```bash
git add -A docs/history.md docs/history/
if [ -z "$(git status --porcelain docs/history.md docs/history/)" ]; then
    echo "Error: doc-append produced no changes for #<N>" >&2
    exit 1
fi
git commit -m "docs(history): record issue #<N>"
```

The empty-staging check catches the case where `doc-append` was a no-op
(entry already present), which would otherwise leave Step F running against a
sentinel that has no committed history entry behind it.

## Step F: promote sentinel to `appended`

```bash
gh api -X PATCH \
    "repos/<owner/repo>/issues/comments/$COMMENT_ID" \
    -f body="<!-- issue-close-sentinel: appended -->"
```

When resuming from triage `ACTION=resume_g`, re-fetch `COMMENT_ID` first:

```bash
COMMENT_ID=$(gh issue view <N> --json comments \
    --jq '[.comments[] | select(.body | test("^<!-- issue-close-sentinel:"))] | first | .url' \
    | grep -oE '[0-9]+$')
```

## Step G: parent body update (sub-issue only)

```bash
bash "$AGENTS_CONFIG_DIR/bin/github-issues/parent-body-update.sh" <owner/repo> <N>
```

No-op when the issue has no parent.

## End

Report: Phase 1 complete for #<N>. Reminder: run `/commit-push`, then after
the PR is merged run `/issue-close-finalize --from-session`.

## Safety notes

- **Recovery**: if Step E (doc-append) fails after Step D (sentinel posted),
  the sentinel remains on the issue but the local `docs/history.md` lacks the
  `#<N>:` entry. `check-phase1-complete.sh` (called by `/commit-push`) will
  detect this and abort the push. Re-running `/issue-close-stage <N>` routes
  via triage `ACTION=resume_e` and retries E only.
- **Untrusted content**: never `eval` issue body, title, or comments.
- **Sentinel body**: hardcoded literal — never interpolate variables or add
  metadata. The Phase 1 marker is shared with `check-phase1-complete.sh` and
  `find-pr-by-marker.sh`; changing the body silently breaks both.
