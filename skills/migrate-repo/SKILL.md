---
name: migrate-repo
description: Migrate a repo from docs/history.md + docs/todo.md to GitHub Issues with canary gates.
user-invocable: true
---

Always run --dry-run first.

## Pre-flight

- `gh auth status` — verify `project` scope is active
- `AGENTS_CONFIG_DIR` must be set

## Procedure

1. Get target repo path from user
2. Preview: `bash "$AGENTS_CONFIG_DIR/bin/github-issues/migration/orchestrate.sh" "$REPO_PATH" --dry-run`
3. Confirm with user
4. Migrate: `bash "$AGENTS_CONFIG_DIR/bin/github-issues/migration/orchestrate.sh" "$REPO_PATH"`

On failure at Step N, resume: `orchestrate.sh "$REPO_PATH" --from-step N`

### When archive files need explicit ordering

If the target repo's `docs/history/` filenames sort alphabetically in the wrong
chronological order (e.g. `legacy-*.md` mixed with `2026-*.md`), pass the explicit
order via `--history-files`:

```bash
orchestrate.sh "$REPO_PATH" --dry-run \
  --history-files "legacy.md,legacy-agents.md,2026-agents.md,2026.md"
```

Filenames are relative to `docs/history/` in the target repo. The current
`docs/history.md` can be included as `../history.md`.

## agents repo (Phase 3)

history.md is already migrated → Step 2 skipped (idempotency). Steps 3–5 run.
