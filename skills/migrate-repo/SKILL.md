---
name: migrate-repo
description: Migrate a repo from docs/history.md + docs/todo.md to GitHub Issues with canary gates.
user-invocable: true
---

Always run --dry-run first.

## Irreversibility hard rule

`gh issue create` consumes monotonically increasing global issue numbers.
Numbers cannot be reused, freed, or reassigned. Every canary stage is
irreversible. The orchestrator is structured so each canary stage runs in a
separate process: never chain stages, never pipe `yes` into the orchestrator,
never run two stages in one command.
`AskUserQuestion` is tool-enforced — never invoke orchestrate.sh inside a pipeline that supplies stdin.

## Pre-flight

- `gh auth status` — verify `project` scope is active
- `AGENTS_CONFIG_DIR` must be set
- Step 1 label setup delegates to `bin/github-issues/bootstrap-labels.sh`.

## Procedure

MR-1. Get target repo path from user.
MR-2. Preview + capture snapshot: `eval "$(bash "$AGENTS_CONFIG_DIR/skills/migrate-repo/scripts/preview-and-capture.sh" "$REPO_PATH")"`. Runs dry-run, mirrors output to stderr, and exports `MIGRATE_ACK_UP_TO_ISSUE_N` + `MIGRATE_ACK_SELF_COUNT_AT_ACK`.
MR-3. AskUserQuestion: "Dry-run output reviewed (if WARNING about existing issues was shown, migration issues will permanently lose the 'early issue numbers = history chronology' invariant). Proceed to history canary 1, or abort migration?" Options: "proceed" / "abort". On proceed: run the canary-1 command shown in the next step. On abort: stop the skill before any irreversible mutation.
MR-4. **History canary 1**: `MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N="$MIGRATE_ACK_UP_TO_ISSUE_N" MIGRATE_ACK_SELF_COUNT_AT_ACK="$MIGRATE_ACK_SELF_COUNT_AT_ACK" bash "$AGENTS_CONFIG_DIR/bin/github-issues/migration/orchestrate.sh" "$REPO_PATH" --from-step 2 --stage canary-1`
   AskUserQuestion: "History canary 1 issues created at the printed URL — proceed to canary 2, or abort migration?" Options: "proceed" / "abort". On proceed: run the canary-2 command shown in the next step. On abort: stop the skill; resume later via the documented `--from-step N --stage S` path from a new session.
MR-5. **History canary 2**: `MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N="$MIGRATE_ACK_UP_TO_ISSUE_N" MIGRATE_ACK_SELF_COUNT_AT_ACK="$MIGRATE_ACK_SELF_COUNT_AT_ACK" bash "$AGENTS_CONFIG_DIR/bin/github-issues/migration/orchestrate.sh" "$REPO_PATH" --from-step 2 --stage canary-2`
   AskUserQuestion: "History canary 2 issues created at the printed URL — proceed to full, or abort?" Options: "proceed" / "abort". On proceed: run the full command shown in the next step. On abort: stop the skill; resume later via the documented `--from-step N --stage S` path from a new session.
MR-6. **History full**: `MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N="$MIGRATE_ACK_UP_TO_ISSUE_N" MIGRATE_ACK_SELF_COUNT_AT_ACK="$MIGRATE_ACK_SELF_COUNT_AT_ACK" bash "$AGENTS_CONFIG_DIR/bin/github-issues/migration/orchestrate.sh" "$REPO_PATH" --from-step 2 --stage full`
MR-7. **Todo canary 1**: `MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N="$MIGRATE_ACK_UP_TO_ISSUE_N" MIGRATE_ACK_SELF_COUNT_AT_ACK="$MIGRATE_ACK_SELF_COUNT_AT_ACK" bash "$AGENTS_CONFIG_DIR/bin/github-issues/migration/orchestrate.sh" "$REPO_PATH" --from-step 3 --stage canary-1`
   AskUserQuestion: "Todo canary 1 issues created at the printed URL — proceed to canary 2, or abort?" Options: "proceed" / "abort". On proceed: run the canary-2 command shown in the next step. On abort: stop the skill; resume later via the documented `--from-step N --stage S` path from a new session.
MR-8. **Todo canary 2**: `MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N="$MIGRATE_ACK_UP_TO_ISSUE_N" MIGRATE_ACK_SELF_COUNT_AT_ACK="$MIGRATE_ACK_SELF_COUNT_AT_ACK" bash "$AGENTS_CONFIG_DIR/bin/github-issues/migration/orchestrate.sh" "$REPO_PATH" --from-step 3 --stage canary-2`
   AskUserQuestion: "Todo canary 2 issues created at the printed URL — proceed to full, or abort?" Options: "proceed" / "abort". On proceed: run the full command shown in the next step. On abort: stop the skill; resume later via the documented `--from-step N --stage S` path from a new session.
MR-9. **Todo full**: `MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N="$MIGRATE_ACK_UP_TO_ISSUE_N" MIGRATE_ACK_SELF_COUNT_AT_ACK="$MIGRATE_ACK_SELF_COUNT_AT_ACK" bash "$AGENTS_CONFIG_DIR/bin/github-issues/migration/orchestrate.sh" "$REPO_PATH" --from-step 3 --stage full`
MR-10. **Step 4 + 5 + 6**: `MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N="$MIGRATE_ACK_UP_TO_ISSUE_N" MIGRATE_ACK_SELF_COUNT_AT_ACK="$MIGRATE_ACK_SELF_COUNT_AT_ACK" bash "$AGENTS_CONFIG_DIR/bin/github-issues/migration/orchestrate.sh" "$REPO_PATH" --from-step 4` (continuous; no `--stage`). Step 6 stages the allowlist (`.github/labels.yml`, `.github/ISSUE_TEMPLATE/`, `.gitignore`, `docs/todo.md`), commits with `chore(migration): apply /migrate-repo Step 1/3 artifacts`, and pushes to `origin`.

On failure at Step N, resume in a new session: re-run Step 2 (`preview-and-capture.sh`) to capture a fresh snapshot pair (`MIGRATE_ACK_UP_TO_ISSUE_N`, `MIGRATE_ACK_SELF_COUNT_AT_ACK`) — accounts for issues already self-migrated. Then re-run Step N's command with `MIGRATE_ACK_EXISTING_ISSUES=1` + both snapshot env vars prefixed. Re-dry-run is mandatory on resume; the Layer C gate fires on every live step.

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

history.md is already migrated → Step 2 skipped (idempotency). Steps 3–6 run.
