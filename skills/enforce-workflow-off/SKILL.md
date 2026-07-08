---
name: enforce-workflow-off
description: Suspend workflow and worktree enforcement for the current session (subsumes WORKTREE_OFF).
user-invocable: true
---

Generate a 1-line reason from the current context describing the intended action, then run:

`echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: {reason}>>"`

WORKFLOW_OFF has "ask" permission — a user confirmation dialog fires before enforcement is suspended.
WORKFLOW_ENFORCE_WORKFLOW_ON has "allow" permission — auto-approved, no dialog.

Run `/enforce-workflow-on` when done to restore enforcement.

See `rules/workflow-off.md` for full details on what is and is not bypassed.
