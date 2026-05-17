# User Verification — Shared Protocol

Used by `CLAUDE.md` step 8 (ENFORCE_WORKTREE=off post-implementation) and
`skills/worktree-end/SKILL.md` (steps 3b and 4, ENFORCE_WORKTREE=on after merge
intent is captured). The protocol is the same in both modes; only the surfaced
context differs.

## Protocol

**Step 1 — Emit the sentinel**

Run, as its own Bash tool call:

    echo "<<WORKFLOW_USER_VERIFIED: <reason>>>"

Attach `: <reason>` describing what the user is approving (e.g.
`"PR #314 — approving merge to main"` or
`"Approving the staged diff before /commit-push"`). The bare form
`<<WORKFLOW_USER_VERIFIED>>` is still accepted but emits a soft warning; the
reason becomes part of the on-disk audit record. Set the Bash `description`
to the same short sentence so the permission dialog shows it.

The sentinel command is in `permissions.ask` (`settings.json`), so Claude Code
will present a permission dialog. Do not pre-empt the dialog with
`AskUserQuestion` — the dialog is the load-bearing wall.

**Step 2 — Context surfaces automatically**

The `hooks/show-user-verified-context.js` PreToolUse hook fires when it sees
the sentinel command, and emits a `User verification context:` systemMessage
**before** the permission dialog renders. The message lists:

- Staged files (`git diff --cached --name-only` against the Bash tool's cwd);
  shows `(none)` when nothing is staged.
- `Open PR: <url>` when `gh pr view` returns a URL in the same cwd; omitted
  otherwise.

The orchestrator should not pre-print this context — the hook is the
authoritative source and duplication would confuse the display.

**Step 3 — User answers the dialog**

- **Allow** → proceed to the next workflow step (`/commit-push`, `gh pr merge`,
  etc., as defined by the caller).
- **Deny** → stop. Do not retry. Re-issue is the user's call.

## Notes

- In ENFORCE_WORKTREE=off mode: if `git diff --cached --name-only` returns zero
  files AND `gh pr view` returns no URL, the orchestrator should skip the
  sentinel emit entirely — there is nothing to verify. The hook's
  `Staged files: (none)` text is a safety net for edge cases, not a substitute
  for meaningful context.
- In ENFORCE_WORKTREE=on mode (worktree-end steps 3b/4): a PR URL is always
  available, so the sentinel is always emitted regardless of staged file count.
- AUTO_MERGE_PR=on (worktree-end step 3) skips the merge-strategy
  `AskUserQuestion` only; the sentinel emit in step 4 is still subject to the
  permission dialog and the hook still fires.
- Detection is strictly on `tool_input.command` matching the
  `<<WORKFLOW_USER_VERIFIED>>` / `<<WORKFLOW_USER_VERIFIED: <reason>>>` family.
  Sentinel-shaped strings in stdout (cat/grep output) do not trigger the hook.
