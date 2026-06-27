---
name: issue-close-migrated
description: Close an issue as status:migrated or status:cancelled with --reason not_planned. Applies label, posts comment, and closes.
user-invocable: false
---

Close issue `<N>` as migrated (merged into another issue) or cancelled.

**Usage:**
- `/issue-close-migrated <N> --type migrated --into <M>` — issue N merged into M
- `/issue-close-migrated <N> --type cancelled` — issue N cancelled

`--into <M>` is **required** for `--type migrated` and **prohibited** for `--type cancelled`.

## Pre-flight

1. Parse `N`, `TYPE`, and (if migrated) `INTO` from the invocation arguments.
2. Verify issue `N` is OPEN: `gh issue view N --json state --jq .state`. Not OPEN → report and exit 0.
3. For `--type migrated`: verify issue `INTO` is OPEN. Not OPEN → report and exit 0.

Run: `bash "$AGENTS_CONFIG_DIR/skills/issue-close-migrated/scripts/pre-flight.sh" "$N" "$TYPE" "$INTO" || { echo "Pre-flight failed — check issue state"; exit 0; }`

## Procedure

Run `bin/github-issues/close-not-planned.sh`:
```
bash "$AGENTS_CONFIG_DIR/bin/github-issues/close-not-planned.sh" \
    --type "$TYPE" $([ "$TYPE" = "migrated" ] && echo "--into $INTO") \
    "$N"
```

The `gh issue close` inside `close-not-planned.sh` is a subprocess of the Bash tool command — `enforce-issue-close.js` (PreToolUse) fires only on the Bash tool command head, not on subprocess calls. No bypass marker is required.

## Rules

- Always close with `--reason not_planned` via `close-not-planned.sh`. Never use `--reason completed` for migrated or cancelled issues.
- Never invoke `gh issue close` directly from this skill — use `close-not-planned.sh`.
