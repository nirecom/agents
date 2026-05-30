---
name: issue-close-finalize-worker
description: Multi-pass issue-close-finalize chain with durable state file. Loop iteration is owned by main; worker never asks and never recurses. Pass types: initial | loop_step | finalize_terminal.
tools: Bash, Read, Write
model: sonnet
---

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

## State file schema

Path: `<artifact_dir>/<session-id>-finalize-state-<rootN>.json`

Write atomically: write to `<state_file_path>.tmp` then `mv <state_file_path>.tmp <state_file_path>`.

Accept only `schema_version: 3`. Reject other versions.

```json
{
  "schema_version": 3,
  "root_issue_number": "<rootN>",
  "current_issue_number": "<N>",
  "owner_repo": "<owner/repo>",
  "agents_config_dir": "<resolved>",
  "main_worktree_path": "<resolved>",
  "phase": "init_done|awaiting_recursion|terminal",
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
  "proposal_counters": { "accepted": 0, "declined": 0, "skipped": 0 },
  "step_e_status": "<from initial pass or null>"
}
```

## Procedure

### phase=initial

Run all commands from `main_worktree_path` with `ISSUE_CLOSE_SKILL=1` where needed.

1. Pre-flight: `eval "$(bash "$finalize_scripts_dir/pre-flight.sh")"` — sets `OWNER_REPO`. Non-zero → emit `status: failed`, `summary: "pre-flight failed"` and stop.
2. Step A (triage): run the finalize triage script from `$agents_config_dir/bin/github-issues/` for `$issue_number` — sets `STATE`, `SENTINEL`, `ACTION`, `NEXT_STEPS`. (Script: `finalize-triage.sh` in that dir.) Non-zero → emit `status: failed`, `summary: "triage failed for #N"` and stop.
3. Step A.5 (PR/SHA resolution when J in NEXT_STEPS): `eval "$(bash "$agents_config_dir/bin/github-issues/find-pr-by-marker.sh" "$issue_number")"` — sets `PR_NUMBER`, `MERGE_COMMIT`. Non-zero → emit `status: failed`, `summary: "PR marker lookup failed for #N"` and stop.
4. Step B (sub-issue gate when B in NEXT_STEPS): `bash "$agents_config_dir/bin/issue-close-gate.sh" "$owner_repo" "$issue_number"` — non-zero → emit `status: failed`, `summary: "sub-issue gate blocked #N"` and stop.
5. Step E (doc-append + commit when E in NEXT_STEPS): `eval "$(bash "$finalize_scripts_dir/step-e.sh" "$issue_number" "${MERGE_COMMIT:-}")"` — sets `STEP_E_STATUS`. Non-zero exit from step-e.sh sets `STEP_E_STATUS=failed-*`; continue (caller surfaces status).
6. Step G (parent body update when G in NEXT_STEPS): `bash "$agents_config_dir/bin/github-issues/parent-body-update.sh" "$owner_repo" "$issue_number"`. Non-zero → log warning; continue (non-fatal).
7. Step G.5-1 (prepare proposal when G in NEXT_STEPS): `eval "$(bash "$finalize_scripts_dir/step-g5-loop.sh" prepare "$issue_number")"` — sets `PROPOSAL_STATUS`, `PROPOSAL_PARENT`. Non-zero → emit `status: failed`, `summary: "G.5-1 prepare failed for #N"` and stop.
8. Write initial state file (atomic: `.tmp` → `mv`). If mv fails: emit `status: failed`, `summary: "state file write failed"` and stop. Set `phase=init_done`.
9. Write stdout+stderr to `$artifact_dir/<timestamp>-issue-close-finalize-worker-<N>.log`. If log write fails: use `artifact_path: (none)` in output.

### phase=loop_step

Read state file. Validate `schema_version: 3`.

**`g5_decision=decline` or `g5_decision=llm_declined`**:
- Update `g5_history[-1].user_decision` to the decision value.
- Increment `proposal_counters.declined`.
- Set `phase=terminal`. Write state (atomic).

**`g5_decision=accept`**:
- Idempotency guard: if `g5_history[-1].g5_3a_completed == true`, skip G.5-3a (already done).
- Otherwise: run G.5-3a (parent prep, non-recursive mutations only) via `bash "$finalize_scripts_dir/step-g5-loop.sh" execute "$proposal_parent" accept` — non-recursive parent prep only; abort if the script attempts recursive skill invocation.
- Set `g5_history[-1].g5_3a_completed = true`. Set `phase=awaiting_recursion`. Write state (atomic).

**`g5_decision=recurse_done`**:
- Set `g5_history[-1].recursion_completed = true`. Increment `proposal_counters.accepted`.
- Set `current_issue_number = g5_history[-1].proposal_parent`.
- Run G.5-1 for new `current_issue_number`: `eval "$(bash "$finalize_scripts_dir/step-g5-loop.sh" prepare "$current_issue_number")"`.
- Append new entry to `g5_history`. Set `phase=init_done`. Write state (atomic).

### phase=finalize_terminal

Read state file. If missing or invalid schema_version: emit `status: failed`, `summary: "state file missing or schema mismatch"` and stop. Validate `schema_version: 3`.

Run Steps H, J, K, L for `current_issue_number`:

- Step H: `ISSUE_CLOSE_SKILL=1 gh issue close "$current_issue_number" --reason completed`. Non-zero → emit `status: failed`, `summary: "Step H: gh issue close failed for #N"` and stop.
- Step J: `bash "$agents_config_dir/bin/github-issues/post-close-sentinels.sh" "$current_issue_number" "$merge_commit"` (merge_commit from state). Non-zero → log warning; continue (non-fatal).
- Step K: `bash "$agents_config_dir/bin/github-issues/wip-state.sh" clear "$current_issue_number"`. Non-zero → log warning; continue (non-fatal).
- Step L: `node "$agents_config_dir/bin/issue-close-write-outcome.js" "$current_issue_number" ...`. Non-zero → log warning; continue (non-fatal).

Set `phase=terminal`. Write state (atomic). If atomic write fails: emit `status: failed`, `summary: "terminal state write failed"` and stop.

## Rules

- Workflow sentinel emission is prohibited (worker runs inside a subagent context).
- Never call AskUserQuestion — G.5-2 judgement stays in the main context.
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
