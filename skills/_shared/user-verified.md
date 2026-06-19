# User Verification — Shared Protocol

`<<WORKFLOW_USER_VERIFIED: reason>>` is the **final** approval from the user before
releasing the work (commit/merge). Emit it exactly once, at the moment the user is
asked "is this ready to ship?".

## When to emit

**`ENFORCE_WORKTREE=off`** — emit in `CLAUDE.md` WF-CODE-8, immediately before `/commit-push`.

**`ENFORCE_WORKTREE=on`** — emit in `/worktree-end` Steps 3b and 4 (after the PR is open,
immediately before merge). Never emit earlier in the workflow — the PR must exist first,
because the user is approving the merge of a specific PR, not an abstract diff.

## Preflight — risk-category gate (#833)

Before emitting the sentinel, run:

    bash "$AGENTS_CONFIG_DIR/bin/check-verification-gate.sh"

Parse its structured stdout (each line: `CATEGORY: <token>\tQUESTION: <text>`).

### Interactive mode (default)

Count matched categories:
- **Zero matches** (empty stdout) → no risk category. Skip the gate; proceed to Protocol.
- **One match** → single-choice AskUserQuestion using the `QUESTION:` text. Options: `Yes — verified` / `No — skip verification this time`. `Yes`: proceed. `No`: proceed but log the unverified category to `WORKTREE_NOTES.md ## Unverified Categories`.
- **Multiple matches** → single multi-select AskUserQuestion with one option per category (label = `QUESTION:` text), plus `Skip all — proceed without verification`. Selected categories are verified. Unselected categories are logged to `WORKTREE_NOTES.md ## Unverified Categories`. Emission proceeds regardless.

### Non-interactive mode

When `$CI` or `$CLAUDE_NON_INTERACTIVE` is set:
- Skip AskUserQuestion.
- Emit one stderr warning per matched category: `WARNING: verification-gate category <token> not interactively confirmed (non-interactive mode).`
- Log each matched category to `WORKTREE_NOTES.md ## Unverified Categories`.
- Proceed with sentinel emission.

### Failure mode

Exit 3 from the tool → fail-safe. In interactive mode ask "Verification gate could not run — proceed anyway?" (Yes/No). In non-interactive mode: log warning, proceed.

Compatibility with PR #818: this gate runs after `check-unstaged-tracked.sh` (WE-3) and before the `WORKFLOW_USER_VERIFIED` sentinel. The two guards are orthogonal.

## Protocol

**Emit the sentinel directly** as its own Bash call — no narrative prelude, no PR URL restated in chat:

    echo "<<WORKFLOW_USER_VERIFIED: <reason>>>"

The `: <reason>` is mandatory — describe what the user is approving
(e.g. `"PR #314 — approving merge to main"`). Set the Bash `description` to the
same sentence so the permission dialog shows it.

`hooks/show-user-verified-context.js` fires before the dialog (SSOT) and surfaces:
- Staged files (`git diff --cached --name-only`), or `(none)`
- `Open PR: <url>` when available
- The approval instruction line shown above the Allow / Deny buttons

Do not pre-print this context, the PR URL, or the approval instruction in chat —
the hook is the single source of truth for the dialog's surrounding text.

**User answers the dialog**

- **Allow** → proceed to the next step (`/commit-push`, `gh pr merge`, etc.)
- **Deny** → stop. Do not retry.

## Notes

- `AUTO_MERGE_PR=on` skips the merge-strategy `AskUserQuestion` in `/worktree-end` Step 3;
  the sentinel emit in Step 4 still requires user approval via the permission dialog.
- Detection is on `tool_input.command` matching the sentinel form. Sentinel strings in
  stdout (cat/grep output) do not trigger the hook.
- Preflight runs once per emission path. /worktree-end Steps WE-4b, WE-7, and WE-8 all inherit it via this shared protocol — no per-skill duplication.
- Unverified categories are persisted to WORKTREE_NOTES.md ## Unverified Categories so /worktree-end can show them in the final summary.
