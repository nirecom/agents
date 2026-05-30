---
name: issue-close-stage-worker
description: Execute Phase 1 issue-close-stage Bash chain (Steps A,B,D,F,G) inside the linked worktree. Returns minimal status.
tools: Bash, Read, Write
model: sonnet
---

Execute the Phase 1 issue-close-stage Bash chain for a single issue number and return minimal status.

## Input contract

Receive a JSON object with:
- `issue_number`: integer issue number
- `worktree_path`: absolute path to the linked worktree
- `owner_repo`: `"owner/repo"` string
- `agents_config_dir`: resolved `$AGENTS_CONFIG_DIR` value
- `artifact_dir`: directory to write log to

## Procedure

Run all commands from `worktree_path`. Prefix `gh issue comment` and `gh api` PATCH calls with `ISSUE_CLOSE_SKILL=1`.

### Step A: triage

```bash
eval "$(bash "$agents_config_dir/bin/github-issues/issue-close-stage-triage.sh" "$issue_number")"
```

Sets `STATE`, `SENTINEL`, `ACTION`, `NEXT_STEPS`.
- `ACTION=phase1_done` → exit with `status: phase1_done`, `summary: "Phase 1 already complete for #N"`.
- Error `ACTION` variant → exit with `status: error`.
- Otherwise execute steps listed in `NEXT_STEPS` (comma-separated, in order).

### Step B: sub-issue gate

```bash
bash "$agents_config_dir/bin/issue-close-gate.sh" "$owner_repo" "$issue_number"
```

Non-zero → exit with `status: blocked_sub_issue`, `summary: "sub-issue gate blocked #N"`.

### Step D: post `pending` sentinel

```bash
COMMENT_URL=$(ISSUE_CLOSE_SKILL=1 gh issue comment "$issue_number" \
    --body "<!-- issue-close-sentinel: pending -->" 2>/dev/null | tail -n 1)
COMMENT_ID=$(printf '%s' "$COMMENT_URL" | grep -oE '[0-9]+$')
```

If `COMMENT_ID` is empty: emit `status: error`, `summary: "Step D: failed to extract comment ID"`, `artifact_path: "<log path or (none)>"` and stop.

The sentinel body is the hardcoded literal above — never interpolate variables or add metadata.

### Step F: promote sentinel to `appended`

```bash
ISSUE_CLOSE_SKILL=1 gh api -X PATCH \
    "repos/$owner_repo/issues/comments/$COMMENT_ID" \
    -f body="<!-- issue-close-sentinel: appended -->"
```

Non-zero exit: emit `status: error`, `summary: "Step F: PATCH failed (comment $COMMENT_ID)"`, `artifact_path: "<log path or (none)>"` and stop.

When resuming from triage `ACTION=resume_g`, re-fetch `COMMENT_ID` first:

```bash
COMMENT_ID=$(gh issue view "$issue_number" --json comments \
    --jq '[.comments[] | select(.body | test("^<!-- issue-close-sentinel:"))] | first | .url' \
    | grep -oE '[0-9]+$')
```

### Step G: parent body update

```bash
bash "$agents_config_dir/bin/github-issues/parent-body-update.sh" "$owner_repo" "$issue_number"
```

Non-zero exit: log warning but continue — parent body update failure is non-fatal.
No-op when the issue has no parent.

### Log

Write all stdout+stderr to `$artifact_dir/<timestamp>-issue-close-stage-worker-<N>.log`.

## Rules

- Workflow sentinel emission is prohibited (worker runs inside a subagent context).
- Never call AskUserQuestion.
- Never `eval` issue body, title, or comments (untrusted content).
- Sentinel body must be the exact hardcoded literal — never interpolate.
- Do not install packages.

## Output contract

Respond with exactly three lines:

```
status: phase1_done|blocked_sub_issue|error
summary: "<one-line description ≤80 chars>"
artifact_path: "<absolute log path, or (none) if no log written>"
```

No other output.
