---
name: enforce-workflow-off
description: Suspend workflow and worktree enforcement for the current session (subsumes WORKTREE_OFF).
user-invocable: true
---

The session-scoped escape hatch. Use only as a last resort, for the cases `rules/workflow-off.md` names; that rule owns the trigger, this skill owns the procedure.

## When the user invoked this skill

Generate a 1-line reason from the current context describing the intended action, then run:

`echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY: [{category}] {reason}>>"`

Explicit user invocation IS the human decision — it carries the same trust as the EMERGENCY escape hatch, so the Phase1 clearance examination is deliberately bypassed here (#1780).
The "ask" permission still fires a user confirmation dialog; the activation is still recorded in the supervisor audit trail as an escape_hatch_event.
Never emit this sentinel on your own initiative — only when the user invoked this skill.
Provenance is recorded independently of this instruction: typing `/enforce-workflow-off` stamps the audit record `provenance=user_skill_invocation` for either target this skill covers, any other route — and any invocation record that cannot be verified and consumed — stamps `provenance=unattributed` (which means "not provably user-invoked", not "misused").

Use `bash "$AGENTS_CONFIG_DIR/bin/request-off-clearance"` instead when YOU (not the user) need an OFF departure; it mints the clearance the non-emergency sentinel below requires.

## Sentinels

| Command | Permission | Effect |
|---|---|---|
| the clearance-gated standard WORKFLOW_ENFORCE_WORKFLOW_OFF form — never emitted by this skill; see `rules/workflow-off.md` | **ask** | Creates `${sid}.workflow-off`; suspends workflow enforcement (and, subsumed, worktree enforcement) |
| `echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY: [{category}] {reason}>>"` | **ask** | Same marker, but bypasses the Phase1 clearance examination |
| `echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: {reason}>>"` | **allow** (auto-approved) | Removes the marker; restores enforcement |
| `echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: {reason}>>"` | **ask** | Creates `${sid}.worktree-off`; lifts only `enforce-worktree.js` |
| `echo "<<WORKFLOW_ENFORCE_WORKTREE_ON: {reason}>>"` | **allow** (auto-approved) | Removes that marker; worktree enforcement restored |

The `{reason}` field is mandatory and non-empty; the bare sentinel form (no `: {reason}`) is rejected.
For the WORKFLOW_OFF pair, `{reason}` must begin with the granted clearance category as a bracketed token — `[category] free text` — spelled exactly as the `category` on the clearance token minted by `bin/request-off-clearance`. Any other spelling fails closed.
Prefer WORKFLOW_OFF alone when both are wanted: it subsumes WORKTREE_OFF, so emitting both is redundant. Reach for the WORKTREE_OFF pair only when the sole obstacle is worktree isolation (e.g. `/worktree-end` × Windows CWD-lock recovery), never for ordinary feature work that belongs in a linked worktree.

## Restoring enforcement

Always restore enforcement when the work ends: emit the matching `_ON` command even if the work failed, and even if you are about to stop. It is auto-approved, and the marker is session-scoped, so a session that skips it runs unguarded until it ends. `/enforce-workflow-on` does this for the WORKFLOW pair.
A repeated restore is a silent no-op: deleting a marker that is already gone changes nothing. Enforcement also returns by itself in the next session, since every marker is keyed to the current session id (the hook layer resolves it — Anthropic bug #27987 keeps `$CLAUDE_SESSION_ID` out of Bash subprocesses).

## Scope

Session-scoped: only the session that emitted the sentinel is affected; every concurrent session stays at full enforcement.
Which hooks honour a marker and which never do: `docs/architecture/claude-code/marker-bypass-contract.md` (SSOT). Credential access, the outbound scan, and OS-level system-ops safety are never bypassed.

## Sanctioned-command false-block recovery

When `enforce-worktree.js` unexpectedly blocks a sanctioned command (e.g. a documented step in a skill's cascade script):

1. Retry the command as-is. Sanctioned commands like `git worktree remove <path>` and `git worktree prune` are allowed unconditionally by `isAllowedWorktreeCommand`.
2. If still blocked, file an issue via `/issue-create` so the hook or skill can be fixed at the source.

Do NOT open this hatch to unblock a single command: it disables enforcement session-wide and masks the root cause.
