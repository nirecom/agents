---
name: issue-reconcile
description: Backfill docs/history.md for issues that were closed outside the /issue-close path (web UI, mobile, another shell). Best-effort scan + interactive confirmation.
---

`/issue-close` is the sanctioned close path inside Claude Code, but the
`enforce-issue-close.js` hook only covers Claude Code's Bash tool. Issues
closed elsewhere have no `<!-- issue-close-sentinel: appended -->` comment
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
ISSUE_CLOSE_SKILL=1 bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-to-history.sh" "$NUM"
```

The script is internally idempotent — running it on `history-only` does
nothing harmful — but skip those in step 2 anyway to avoid unnecessary
GitHub API calls.

After a successful append, post the `appended` sentinel so future runs
classify the issue as clean:

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
