---
name: enforce-workflow-off
description: Suspend workflow and worktree enforcement for the current session (subsumes WORKTREE_OFF).
user-invocable: true
---

Generate a 1-line reason from the current context describing the intended action, then run:

`echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY: {reason}>>"`

Explicit user invocation of this skill IS the human decision — it carries the same trust as the EMERGENCY escape hatch, so the Phase1 clearance examination is deliberately bypassed here (#1780).
The "ask" permission still fires a user confirmation dialog; the activation is still recorded in the supervisor audit trail as an escape_hatch_event.
Never emit this sentinel on your own initiative — only when the user invoked this skill.
Provenance is recorded independently of this instruction: typing `/enforce-workflow-off` stamps the audit record `provenance=user_skill_invocation` for either target this skill covers, any other route — and any invocation record that cannot be verified and consumed — stamps `provenance=unattributed` (which means "not provably user-invoked", not "misused").

Use `bash "$AGENTS_CONFIG_DIR/bin/request-off-clearance"` instead when YOU (not the user) need an OFF departure.

Run `/enforce-workflow-on` when done to restore enforcement.

See `rules/workflow-off.md` for full details on what is and is not bypassed.
