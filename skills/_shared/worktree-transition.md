# Worktree Transition — Shared Protocol

Binding the session to a linked worktree, and releasing that binding before the session closes.
This fragment owns the entry, exit, and recovery procedures; every other location points here instead of restating them.

## Entry — after /worktree-start

Call the native `EnterWorktree` tool with the absolute worktree path decided at `/worktree-start` WS-3.
When that tool is unavailable in the current execution context, start a new session with the worktree as its working directory — there is no in-session substitute.
One confirmation dialog is shown for worktrees outside `.claude/worktrees/` — that is normal since v2.1.206; approve it.
Confirm once after entering that `git rev-parse --show-toplevel` returns the worktree path.

## Exit — before session close

Call the native `ExitWorktree` tool right after `/worktree-end` WE-13 has changed CWD to the main worktree.
When that tool is unavailable in the current execution context, skip silently.
Skipping it leaves the extension host holding the session worktree binding, and the session disappears from the thread list after a restart.

## Recovery — blocked outside the recorded worktree

Enter the path the block reason reports as `Session worktree:` using the `## Entry` procedure above, then retry the blocked tool call.
Do not assume that writing to an absolute path inside the worktree avoids the block — no binding is established that way, so the same block applies.
Only when entry is genuinely impossible, emit `<<WORKFLOW_ENFORCE_WORKTREE_OFF: {reason}>>`, and restore enforcement with `<<WORKFLOW_ENFORCE_WORKTREE_ON: {reason}>>` once the work is done.
Emit `<<WORKFLOW_ENFORCE_WORKFLOW_OFF: {reason}>>` only when a wider bypass than the worktree guard is genuinely required.

## Notes

- The upstream confirmation dialog cannot be suppressed from this repository (issue #1610).
- `cd` inside a Bash call never moves the session CWD — the shell is reset after every call, so it cannot establish or release a binding.
- Entering relocates the session transcript to the worktree's project directory; the session leaves the launch directory's thread list.
