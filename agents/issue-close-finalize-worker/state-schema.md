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

## phase=initial state file write template

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
