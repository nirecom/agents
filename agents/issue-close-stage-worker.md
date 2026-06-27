---
name: issue-close-stage-worker
description: Execute Phase 1 issue-close-stage Bash chain (Steps A,B,D,F,G) inside the linked worktree. Returns minimal status.
tools: Bash, Read, Write
model: sonnet
---
<!-- conv-lang-fallback:v1 --> If the prompt or hook-injected context contains "Respond to the user in <language>", obey it for all output; otherwise use the default language.

Execute the Phase 1 issue-close-stage Bash chain for a single issue number and return minimal status.

## Input contract

Receive a JSON object with:
- `issue_number`: integer issue number
- `worktree_path`: absolute path to the linked worktree
- `owner_repo`: `"owner/repo"` string
- `agents_config_dir`: resolved `$AGENTS_CONFIG_DIR` value
- `artifact_dir`: directory to write log to
- `issue_repo`: string (optional) — `<owner/repo>` or `<repo>`; omit for current-repo issues. NOTE: stage-worker does NOT propagate `issue_repo` to `gh` calls in Steps D/F/G — those target the current-repo PR/worktree. Cross-repo Phase 1 support is future scope.

## Procedure

Run from `worktree_path`. All commands run in that directory.

Run the stage chain:

```bash
cd "$worktree_path"
eval "$(AGENTS_CONFIG_DIR="$agents_config_dir" \
  bash "$agents_config_dir/skills/issue-close-stage/scripts/run-stage-chain.sh" \
  "$issue_number" "$owner_repo")"
```

- `STATUS=phase1_done` → proceed to Log step.
- `STATUS=blocked_sub_issue` → emit `status: blocked_sub_issue`, `summary: "$SUMMARY"` and stop.
- `STATUS=error` → emit `status: error`, `summary: "$SUMMARY"`, `artifact_path: "<log path or (none)>"` and stop.

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
