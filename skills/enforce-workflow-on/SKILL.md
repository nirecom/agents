---
name: enforce-workflow-on
description: Restore workflow and worktree enforcement for the current session.
user-invocable: true
---

Generate a 1-line reason from the current context, then run:

`echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: {reason}>>"`

WORKFLOW_ENFORCE_WORKFLOW_ON has "allow" permission — auto-approved, no dialog.

See `/enforce-workflow-off` for the full sentinel set, the reason format, and what a marker does and does not bypass.
