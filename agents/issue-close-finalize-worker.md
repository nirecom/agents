---
name: issue-close-finalize-worker
description: Multi-pass issue-close-finalize chain with durable state file. Loop iteration is owned by main; worker never asks and never recurses. Pass types: initial | loop_step | finalize_terminal.
tools: Bash, Read, Write
model: sonnet
---
<!-- conv-lang-fallback:v1 --> If the prompt or hook-injected context contains "Respond to the user in <language>", obey it for all output; otherwise use the default language.

Execute one pass of the finalize chain using a durable state file for multi-pass coordination. The G.5 recursion is owned by the calling main context — this worker never recurses.

## Input contract

Receive a JSON object with `phase` determining the pass type:

**`phase=initial`**:
- `issue_number`: integer
- `agents_config_dir`: resolved path
- `finalize_scripts_dir`: resolved absolute path to the finalize skill's `scripts/` directory
- `main_worktree_path`: absolute path to main worktree
- `state_file_path`: absolute path to write state JSON (may not exist yet)
- `root_issue_number`: integer (equals `issue_number` for the outermost call)
- `owner_repo`: `"owner/repo"` string
- `artifact_dir`: directory to write log to
- `issue_repo`: `"<owner/repo> or <repo>"` — omit for current-repo issues (optional)

**`phase=loop_step`**:
- `state_file_path`: absolute path to existing state JSON
- `g5_decision`: `"accept"` | `"decline"` | `"llm_declined"` | `"recurse_done"`
- `agents_config_dir`: resolved path
- `finalize_scripts_dir`: resolved absolute path to the finalize skill's `scripts/` directory
- `artifact_dir`: directory to write log to

**`phase=finalize_terminal`**:
- `state_file_path`: absolute path to existing state JSON
- `agents_config_dir`: resolved path
- `finalize_scripts_dir`: resolved absolute path to the finalize skill's `scripts/` directory
- `artifact_dir`: directory to write log to
- `session_id`: session ID string (resolves env-var propagation gap for Step ICF-K)
- `outcome_file_path`: absolute path to write outcome JSON (resolves env-var propagation gap for Step ICF-K)

## State file schema

Path: `<artifact_dir>/<session-id>-finalize-state-<rootN>.json`

Write atomically: write to `<state_file_path>.tmp` then `mv <state_file_path>.tmp <state_file_path>`.

Accept only `schema_version: 3`. Reject other versions.

```json
{
  "schema_version": 3,
  "root_issue_number": "<rootN>",
  "current_issue_number": "<N>",
  "issue_repo": "<owner/repo or repo — omit for current-repo issues>",
  "owner_repo": "<owner/repo>",
  "agents_config_dir": "<resolved>",
  "main_worktree_path": "<resolved>",
  "phase": "init_done|awaiting_recursion|terminal",
  "triage_action": "<resume_e|resume_h|resume_j|auto_close_path|meta_pending_subs|stuck_*>",
  "g5_loop_iteration": 0,
  "g5_history": [
    {
      "iteration": 1,
      "issue_number": "<N>",
      "proposal_status": "ok|skipped",
      "proposal_parent": "<P or null>",
      "user_decision": "accept|decline|llm_declined|skipped|null",
      "g5_3a_completed": false,
      "recursion_completed": false
    }
  ],
  "proposal_counters": { "accepted": 0, "declined": 0, "skipped": 0 }
}
```

## Procedure

Run all commands from `main_worktree_path`.

### phase=initial

```bash
cd "$main_worktree_path"
eval "$(AGENTS_CONFIG_DIR="$agents_config_dir" \
  FINALIZE_SCRIPTS_DIR="$finalize_scripts_dir" \
  MAIN_WORKTREE_PATH="$main_worktree_path" \
  bash "$finalize_scripts_dir/run-initial.sh" \
  "$issue_number" "$root_issue_number" "${issue_repo:-}")"
```

`STATUS=failed` → emit `status: failed`, `summary: "$SUMMARY"` and stop.
`STATUS=init_done` → write state file (atomic: `.tmp` → `mv`) using fields from eval output.

State file JSON to write (use values from eval):
```json
{
  "schema_version": 3,
  "root_issue_number": <root_issue_number>,
  "current_issue_number": <issue_number>,
  "issue_repo": "<issue_repo — omit field if empty>",
  "owner_repo": "$OWNER_REPO",
  "agents_config_dir": "<agents_config_dir>",
  "main_worktree_path": "<main_worktree_path>",
  "merge_commit": "$MERGE_COMMIT",
  "phase": "init_done",
  "triage_action": "$TRIAGE_ACTION",
  "g5_loop_iteration": 0,
  "g5_history": [
    {
      "iteration": 1,
      "issue_number": "<issue_number>",
      "proposal_status": "$PROPOSAL_STATUS",
      "proposal_parent": <PROPOSAL_PARENT or null>,
      "user_decision": null,
      "g5_3a_completed": false,
      "recursion_completed": false
    }
  ],
  "proposal_counters": { "accepted": 0, "declined": 0, "skipped": 0 }
}
```

When `TRIAGE_ACTION=meta_pending_subs`: omit `g5_history` field; main context returns early.

Write log and emit `status: init_done`.

### phase=loop_step

```bash
cd "$main_worktree_path"
eval "$(AGENTS_CONFIG_DIR="$agents_config_dir" \
  FINALIZE_SCRIPTS_DIR="$finalize_scripts_dir" \
  node "$finalize_scripts_dir/run-loop-step.js" \
  "$state_file_path" "$g5_decision")"
```

Emit output status: `$STATUS`. `STATUS=failed` → emit `status: failed`.

### phase=finalize_terminal

```bash
cd "$main_worktree_path"
eval "$(AGENTS_CONFIG_DIR="$agents_config_dir" \
  bash "$finalize_scripts_dir/run-finalize-terminal.sh" \
  "$state_file_path" "$session_id" "$outcome_file_path")"
```

`STATUS=failed` → emit `status: failed`, `summary: "$SUMMARY"` and stop.
`STATUS=terminal` → write log, emit `status: complete`, `summary: "Phase 2 terminal for #N"`.

## Rules

- Workflow sentinel emission is prohibited (worker runs inside a subagent context).
- Never call AskUserQuestion — ICF-F judgement stays in the main context.
- Recursive skill invocation is prohibited — recursion ownership belongs to the main context.
- Atomic writes only: write to `<state_file_path>.tmp` then `mv <state_file_path>.tmp <state_file_path>`.
- Accept only `schema_version: 3` state files.
- Untrusted content: never `eval` issue body, title, or comments.
- `g5_3a_completed` idempotency guard: skip G.5-3a if already true.
- Do not install packages.

## Output contract

Respond with exactly three lines:

```
status: init_done|awaiting_recursion|terminal|complete|failed
summary: "<one-line description ≤80 chars>"
artifact_path: "<absolute state_file_path or log path, or (none) if neither written>"
```

No other output.
