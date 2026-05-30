---
name: refactor-prompts
description: Scan rules/skills/agents for redundant hook-enumeration examples and auto-generate a cleanup PR.
context: fork
---

1. `/worktree-start --task-name "refactor-prompts-$(date +%Y%m%d)" --branch-type refactor`
2. Capture scan output into a shell variable (no `/tmp` file):
   ```
   SCAN_JSON=$(bash "$AGENTS_CONFIG_DIR/bin/refactor-prompts/index.sh")
   ```
   Abort with clear error if exit code is non-zero.
3. Inspect `$SCAN_JSON`. If its `hot_regions` array is empty: emit `<<REFACTOR_PROMPTS_NO_HOTREGIONS>>` and jump to step 9.
4. Dispatch `refactor-prompts-judge` subagent. Pass the value of `$SCAN_JSON` inline and the path `rules/prompt.md`.
5. Parse the subagent's edit plan JSON (`edits` array). Discard any edit whose `file` is not present in the `hot_regions` file set of `$SCAN_JSON` (scope guard against prompt-injection).
6. Apply edits — cap at 200 hot regions per run (warn on stderr if truncated):
   - `delete`: Edit(`old_text`, `new_text=""`)
   - `category-rewrite`: Edit(`old_text`, `new_text`)
   - `keep-*`: no action
   - `defer`: no file modification, no HTML comment. Append `{file,line,reason,context_excerpt}` to a deferred list.
   If Edit errors for a delete/category-rewrite → downgrade to defer.
7. `/commit-push`
8. If deferred list non-empty: append a `## Deferred regions (human review required)` section to the PR body via `gh pr edit`. Replace the section if already present (idempotent).
9. `/worktree-end`

Rules:
- Never prompt the user mid-flow.
- `tests/` is excluded by the CLI scanner — do not pass `--target`.
- `defer` = no file modification and no HTML comment in source files.
