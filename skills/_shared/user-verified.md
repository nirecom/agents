# User Verification — Shared Protocol

`<<WORKFLOW_USER_VERIFIED: reason>>` is the **final** approval from the user before
releasing the work (commit/merge). Emit it exactly once, at the moment the user is
asked "is this ready to ship?".

## When to emit

**`ENFORCE_WORKTREE=off`** — emit in `CLAUDE.md` Step 8, immediately before `/commit-push`.

**`ENFORCE_WORKTREE=on`** — emit in `/worktree-end` Steps 3b and 4 (after the PR is open,
immediately before merge). Never emit earlier in the workflow — the PR must exist first,
because the user is approving the merge of a specific PR, not an abstract diff.

## Protocol

**Step 1 — Emit the sentinel** (its own Bash call):

    echo "<<WORKFLOW_USER_VERIFIED: <reason>>>"

The `: <reason>` is mandatory — describe what the user is approving
(e.g. `"PR #314 — approving merge to main"`). Set the Bash `description` to the
same sentence so the permission dialog shows it.

**Step 2 — Context surfaces automatically**

`hooks/show-user-verified-context.js` fires before the dialog and emits:
- Staged files (`git diff --cached --name-only`), or `(none)`
- `Open PR: <url>` when available

Do not pre-print this context — the hook is authoritative.

**Step 3 — User answers the dialog**

- **Allow** → proceed to the next step (`/commit-push`, `gh pr merge`, etc.)
- **Deny** → stop. Do not retry.

## Notes

- `AUTO_MERGE_PR=on` skips the merge-strategy `AskUserQuestion` in `/worktree-end` Step 3;
  the sentinel emit in Step 4 still requires user approval via the permission dialog.
- Detection is on `tool_input.command` matching the sentinel form. Sentinel strings in
  stdout (cat/grep output) do not trigger the hook.
