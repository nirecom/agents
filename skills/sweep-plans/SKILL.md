---
name: sweep-plans
description: Reclaim stale ~/.workflow-plans/ session artifacts: deletes non-plan files by default; plan and user-requested files only with --include-plan-and-user-requested and approval
user-invocable: true
model: sonnet
---

# /sweep-plans

Reclaim stale session artifacts under `~/.workflow-plans/`.

- Every file falls into one of four classes, decided by its kind in `hooks/lib/plans-artifact-registry.js`: `non-plan`, `plan`, `user-requested`, `unknown`.
- The user flags are `--include-plan-and-user-requested`, `--dry-run`, `--sweep-age-days N`, and `--ci-mode`.

## Procedure

SP-1. Run `bash "$AGENTS_MAIN_ROOT/bin/sweep-plans.sh"` and forward the user's flags verbatim; when they include `--include-plan-and-user-requested` without `--ci-mode` or `--dry-run`, also pass `--gate-session "$CLAUDE_CODE_SESSION_ID"`.
SP-2. Show stdout verbatim; never summarize or filter it.
SP-3. Run the human gate on a `<<<APPROVAL-GATE-SP3` block, checking every Other token against the block's token rows:
   - Stop when stdout has no such block.
   - Note the block's `# gate-id:` value.
   - Ask one `AskUserQuestion` with the options "Delete every listed session" and "Delete nothing"; a subset arrives as tokens typed in Other.
   - Stop without deleting when any Other token is missing from the gate's token rows.
   - Stop on "Delete nothing".
   - Resolve `<PLANS_DIR>` per `skills/_shared/resolve-plans-dir.md`; write the approved tokens, one per line, with the Write tool into `<PLANS_DIR>` as the registry kind `sweep-plans-approved-sessions` (file name `<session-id>-sweep-plans-approved-sessions.txt`).
   - Rerun with `--include-plan-and-user-requested --gate-session "$CLAUDE_CODE_SESSION_ID" --gate-id <noted value> --approved-sessions-file <that file>` plus the user's `--sweep-age-days`; show stdout verbatim.

## Rules

- `--gate-session`, `--gate-id`, and `--approved-sessions-file` are the internal protocol with the script; never offer them to the user.
- `--include-plan-and-user-requested` changes neither the write mode nor the candidate set.
- Approve only tokens shown in the gate; the script repeats the same check against the gate artifact.
- Keep a flagless run non-interactive; never put `AskUserQuestion` on the default path.
- `--ci-mode` is non-interactive; candidates appear only in the JSON `approval_candidates`.
- The approved-sessions file lives in PLANS_DIR; the script owns the gate artifact in the control dir, and the model never writes it.
- Never add `context: fork`: the human gate needs the parent conversation.
