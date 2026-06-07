---
name: issue-reconcile
description: Backfill docs/history.md for issues that were closed outside the /issue-close-stage + /issue-close-finalize path (web UI, mobile, another shell). Best-effort scan + interactive confirmation.
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
- Determine `<owner/repo>` from `gh repo view --json owner,name --jq '.owner.login + "/" + .name'`.

## Step 1: enumerate closed issues (paginated)

```bash
gh issue list --state closed --limit 1000 --paginate \
    --json number,title,body,labels,closedAt,comments \
    | jq -c '.[]'
```

Each output line is one closed-issue JSON object.

## Step 2: classify

For each issue:

```bash
NUM=$(printf '%s' "$LINE" | jq -r .number)
SENTINEL=$(printf '%s' "$LINE" | jq -r '[.comments[].body | select(test("^<!-- issue-close-sentinel: appended"))] | first')
```

Then check history:

```bash
HAS_HISTORY=$(grep -rqE "#${NUM}:" docs/history.md docs/history/ 2>/dev/null && echo yes || echo no)
```

| sentinel | has_history | classification | action |
|----------|-------------|----------------|--------|
| non-null | yes         | clean          | skip |
| non-null | no          | sentinel-only  | append (recovery) |
| null     | yes         | history-only   | skip (history is the SSOT; sentinel can be added) |
| null     | no          | unappended     | prompt the user before appending |

## Step 3: prompt and append

For each non-clean issue, show the user:
- Issue number, title, closedAt
- Classification (sentinel-only / unappended)
- The Background/Changes (or Cause/Fix) the entry would carry

Ask whether to **append**, **skip**, or **stop**.

On "append":

```bash
# Fetch current docs/history.md into a staging file, append via --target,
# validate, then PUT to GitHub via the Contents API. The ISSUE_CLOSE_SKILL=1
# env-var bypass was removed in #672.
STAGING_DIR="$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir")"
STAGE="$STAGING_DIR/reconcile-${NUM}-history.md"
OWNER_REPO=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')
DEF=$(gh api "repos/$OWNER_REPO" --jq '.default_branch')
gh api "repos/$OWNER_REPO/contents/docs/history.md?ref=$DEF" \
    | jq -r '.content' | tr -d '\r\n' | base64 -d > "$STAGE"
bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-to-history.sh" "$NUM" --target "$STAGE"
bash "$AGENTS_CONFIG_DIR/bin/lib/github-contents-write.sh" \
    --owner "${OWNER_REPO%%/*}" --repo "${OWNER_REPO#*/}" \
    --path docs/history.md --file "$STAGE" \
    --message "docs(history): record issue #$NUM" --branch "$DEF"
rm -f "$STAGE"
```

The script is internally idempotent — running it on `history-only` does
nothing harmful — but skip those in step 2 anyway to avoid unnecessary
GitHub API calls.

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
`$(git rev-parse --git-common-dir)/info/issue-reconcile.last`. The skill is
otherwise stateless — every run is a fresh scan.

## End

Report: how many issues were scanned, how many were appended, how many
skipped, and the path to any warnings.
