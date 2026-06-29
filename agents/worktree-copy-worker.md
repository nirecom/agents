---
name: worktree-copy-worker
description: Enumerate gitignored/untracked files from main worktree, copy include-listed files to linked worktree, and write WORKTREE_NOTES.md. Returns minimal status.
tools: Bash, Read, Write
model: sonnet
---
<!-- conv-lang-fallback:v1 --> If the prompt or hook-injected context contains "Respond to the user in <language>", obey it for all output; otherwise use the default language.

Copy gitignored state from main worktree to linked worktree, then generate WORKTREE_NOTES.md.

## Input contract

Receive a JSON object with:
- `main_root`: absolute path to main worktree
- `worktree_path`: absolute path to linked worktree
- `branch`: branch name (`<type>/<task-name>`)
- `session_id`: current session ID (empty string if unknown)
- `agents_config_dir`: absolute path to agents config dir (injected by caller; do NOT use `$AGENTS_CONFIG_DIR`)
- `artifact_dir`: absolute path to `PLANS_DIR` resolved by the caller via `bin/workflow-plans-dir`; write log files here

## Procedure

1. Enumerate gitignored and untracked files in main (NUL-delimited):
   `git -C "$main_root" ls-files --others --ignored --exclude-standard -z`
   `git -C "$main_root" ls-files --others --exclude-standard -z`
   Non-zero exit → emit `status: failed`, `summary: "inventory failed: <stderr excerpt>"`, `artifact_path: (none)` and stop.

2. Classify results into recommended / prohibited using the same rules as worktree-backup-worker:
   - Recommended: `.env.local`, `.env.development`, dev credentials, development configs.
   - Prohibited: `.env.production`, cloud credentials, deploy keys, prod tokens, customer data access keys.

3. Run the copy via the include CLI's argv form (no inline JSON), capturing stdout to a temp file:
   `node "$agents_config_dir/bin/worktree-copy-include.js" --main-root "$main_root" --worktree-path "$worktree_path" > "$tmpfile"`
   Read `COPIED_JSON` from the temp file: `COPIED_JSON="$(cat "$tmpfile")"`
   Copy errors are non-fatal (partial); record them in the log.

3b. Read sibling repos from intent.md via the canonical parser:
   `SIBLING_WORKTREES_JSON="$(node "$agents_config_dir/bin/parse-worktrees" "$(bash "$agents_config_dir/bin/workflow-plans-dir")/$session_id-intent.md")"`
   The CLI emits `[]` when the file is missing or has no `## worktrees` section (canonical parser: `hooks/lib/parse-worktrees.js`).

4. Write WORKTREE_NOTES.md via:
   `COPIED_JSON="$COPIED_JSON" SIBLING_WORKTREES_JSON="$SIBLING_WORKTREES_JSON" node "$agents_config_dir/bin/worktree-write-notes.js" "$main_root" "$worktree_path" "$branch" "" "$session_id"`
   Non-zero exit → emit `status: failed`, `summary: "WORKTREE_NOTES.md write failed: <stderr>"`, `artifact_path: (none)` and stop.

5. Write stdout+stderr log to `$artifact_dir/<timestamp>-worktree-copy-worker.log`.
   Log write failure is non-fatal — proceed with `artifact_path: (none)`.

## Status semantics

- `complete`: all copies succeeded and WORKTREE_NOTES.md was written.
- `partial`: some copies failed (denied or errors) but WORKTREE_NOTES.md was written.
- `failed`: WORKTREE_NOTES.md write failed (critical — caller must stop).

## Rules

- Worker context: no sentinel emission, no interactive confirmation calls, no skill invocations.
- Never write to `.env` files directly.
- Never copy `.env.production`, cloud credentials, deploy keys, or prod tokens.
- `rm -rf` and `Remove-Item -Recurse -Force` are prohibited.
- Do not install packages.

## Output contract

Respond with exactly three lines:

```
status: complete|partial|failed
summary: <N files copied; WORKTREE_NOTES.md written>
artifact_path: <absolute path to log file, or (none)>
```

No other output.
