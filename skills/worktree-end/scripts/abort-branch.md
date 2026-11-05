<!--
Abort branch spec for worktree-end: the cleanup of a session aborted with
`/workflow-abort-accepted` (next-step `REASON=workflow-aborted-cleanup`).
Read it (do not `bash` it); issue each command separately, as with
cleanup-cascade.md. `<main>`, `<branch>`, `<sid>` are placeholders the
orchestrator substitutes at issue time. Design: docs/architecture/claude-code/workflow-abort.md.
-->

Nothing was delivered, so every step that needs a PR or a merge is skipped; every safety step is kept as written in SKILL.md.

## Skipped steps
- WE-4 (pr-state) — skip: `PR_STATE=NONE` would be misread as a bootstrap delivery.
- WE-8 (capture-env.sh) — skip: it needs a PR number and a merge SHA.
- WE-17 (compose doc-append) — skip: no history or changelog entry for an undelivered change.
- Issue close — skip: the aborted session does not close its issues; the WIP marks this session holds (`wip-state check` = `same`) are abandoned instead (A-1); marks of another session are left with a warning.

## Kept steps, in order
1. WE-1 and WE-2 as written.
2. A-1 (WE-3 + WIP release): in the linked worktree run `bash "$AGENTS_MAIN_ROOT/skills/worktree-end/scripts/abort-branch.sh" --session <sid>`. Non-zero → it names the uncommitted tracked changes; stop and let the user commit or stash them. A `warn:` line for an issue (closed issue, unknown state) does not stop the abort.
3. WE-5 (backup), WE-6 (last-chance findings), WE-7 (notes promotion) as written.
4. WE-9 (cd to the main worktree) and WE-9a (ExitWorktree) as written.
5. Cleanup cascade (`cleanup-cascade.md`) WE-10b..WE-18a as written, with two changes:
   - WE-15: run `bash "$AGENTS_MAIN_ROOT/skills/worktree-end/scripts/abort-branch.sh" --delete-branch <branch> --main <main>` instead. It uses `git -C <main> branch -d <branch>`; an unmerged branch is kept with a warning — report it to the user and never force the delete.
   - WE-17: skipped (above).
6. Settle the step: `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --advance --step cleanup --complete` (no `--next`: after an abort cleanup is not the current step, so `--next` emits no `ACTION=`), then run `next-step --session "$SESSION_ID"` once more; it must answer `ACTION=done` / `REASON=workflow-aborted`.
