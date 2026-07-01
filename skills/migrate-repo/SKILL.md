---
name: migrate-repo
description: Migrate a repo from docs/history.md + docs/todo.md to GitHub Issues with canary gates.
user-invocable: true
---

Always run `--dry-run` first.

## Irreversibility hard rule

- `gh issue create` consumes monotonically increasing global issue numbers; they can never be reused, freed, or reassigned. Every canary stage is irreversible.
- Each stage MUST run as its own process: never chain stages, never pipe `yes` into the orchestrator, never run two stages in one command.
- `AskUserQuestion` is the only gate between stages — never invoke `orchestrate.sh` inside a pipeline that supplies stdin.

## Pre-flight

- `gh auth status` — confirm `project` scope is active.
- `AGENTS_CONFIG_DIR` must be set.
- Step 1 label setup is delegated to `bin/github-issues/bootstrap-labels.sh`.

## Procedure

MR-1. Get the migration target path from the user.
   - Never infer `REPO_PATH` from a path mentioned only as documentation / reference / context — accept only the path the user explicitly designates as the target.
   - Resolve `REPO_PATH` to an absolute path, then **AskUserQuestion**: "Migration target = `<abs path>` — correct? (confirm this is NOT the agents repo itself)"
     - "Yes, proceed with this path" → MR-2
     - "No, re-enter the correct path" → re-collect `REPO_PATH`, repeat MR-1

MR-2. Preview + capture the snapshot.
   - Run: `eval "$(bash "$AGENTS_CONFIG_DIR/skills/migrate-repo/scripts/preview-and-capture.sh" "$REPO_PATH")"` — runs the dry-run, mirrors it to stderr, and exports `MIGRATE_ACK_UP_TO_ISSUE_N` + `MIGRATE_ACK_SELF_COUNT_AT_ACK`.
   - Inspect `MIGRATE_SELF_REPO_DETECTED`:
     - `=1` → **AskUserQuestion**: "WARNING: target (`<REPO_PATH>`) is the agents repo itself. Proceed ONLY for an intentional agents-repo Phase 3 self-migration."
       - "Proceed as agents-repo Phase 3" → MR-3
       - "Abort and fix the path" → stop the skill
     - `=0` → MR-3

MR-3. Dry-run review gate. **AskUserQuestion**: "Dry-run reviewed — proceed to History canary 1, or abort?"
   - Note in the question: if an existing-issues WARNING was shown, migrated issues permanently lose the "early issue numbers = history chronology" invariant.
   - "proceed" → MR-4
   - "abort" → stop the skill (no irreversible mutation yet)

### Live stages (MR-4 … MR-10)

Each stage below runs as its own command, formed as `<ACK> <BASE> <stage args>`:
- `<ACK>` = `MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N="$MIGRATE_ACK_UP_TO_ISSUE_N" MIGRATE_ACK_SELF_COUNT_AT_ACK="$MIGRATE_ACK_SELF_COUNT_AT_ACK"`
- `<BASE>` = `bash "$AGENTS_CONFIG_DIR/bin/github-issues/migration/orchestrate.sh" "$REPO_PATH"`

**Gate** (only where the table says "gate"): after the stage's issues appear at the printed URL, **AskUserQuestion** "proceed / abort".
- "proceed" → run the next stage's command.
- "abort" → stop the skill; resume later (see Resume) from a new session.

| Step | Stage | `<stage args>` | After stage |
|------|-------|----------------|-------------|
| MR-4 | History canary 1 | `--from-step 1 --stage canary-1` | gate → MR-5 |
| MR-5 | History canary 2 | `--from-step 2 --stage canary-2` | gate → MR-6 |
| MR-6 | History full | `--from-step 2 --stage full` | → MR-7 (no gate) |
| MR-7 | Todo canary 1 | `--from-step 3 --stage canary-1` | gate → MR-8 |
| MR-8 | Todo canary 2 | `--from-step 3 --stage canary-2` | gate → MR-9 |
| MR-9 | Todo full | `--from-step 3 --stage full` | → MR-10 (no gate) |
| MR-10 | Steps 4–6 | `--from-step 4` (continuous; no `--stage`) | done |

MR-10 note: Step 6 stages the allowlist (`.github/labels.yml`, `.github/ISSUE_TEMPLATE/`, `.gitignore`, `docs/todo.md`), commits `chore(migration): apply /migrate-repo Step 1/3 artifacts`, and pushes to `origin`.

## Resume (after failure or abort at stage N)

Resume in a new session:
- Re-run MR-2 (`preview-and-capture.sh`) for a fresh snapshot pair — accounts for issues already migrated.
- Re-run stage N's command (`<ACK> <BASE> <stage args>`) with the freshly captured snapshot vars.
- Re-dry-run is mandatory on resume; the Layer C gate fires on every live step.

## When archive files need explicit ordering

If `docs/history/` filenames sort in the wrong chronological order (e.g. `legacy-*.md` mixed with `2026-*.md`), pass the order explicitly with `--history-files` — comma-separated, relative to `docs/history/`; include the current `docs/history.md` as `../history.md`. Example: `orchestrate.sh "$REPO_PATH" --dry-run --history-files "legacy.md,legacy-agents.md,2026-agents.md,2026.md"`.

## agents repo (Phase 3)

history.md is already migrated → Step 2 skipped (idempotency). Steps 3–6 run.
