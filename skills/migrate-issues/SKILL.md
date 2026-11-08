---
name: migrate-issues
description: Migrate a repo from docs/history.md + docs/todo.md to GitHub or GitLab issues with canary gates, then record migrate.issues in .agents.json.
user-invocable: true
---

Always run `--dry-run` first.

## Irreversibility hard rule

- Issue creation consumes monotonically increasing global issue numbers; they can never be reused, freed, or reassigned. Every canary stage is irreversible.
- Each stage MUST run as its own process: never chain stages, never pipe `yes` into the orchestrator, never run two stages in one command.
- `AskUserQuestion` is the only gate between stages — never invoke `orchestrate.sh` inside a pipeline that supplies stdin.

## Pre-flight

- GitHub: `gh auth status` — confirm `project` scope is active. GitLab (`HOST=gitlab`): `glab auth status`; issue writes go through `bin/github-issues/lib/host-adapter.sh`, sentinel comments become issue notes, and the Content Date step is skipped.
- `AGENTS_MAIN_ROOT` must be set.
- Step 1 label setup is delegated to `bin/github-issues/migration/orchestrate/label-setup.sh`; a failed label sync stops Step 1.

## Procedure

MI-1. Get the migration target path. Called from `/migrate`: use its `ROOT` as `REPO_PATH` and skip the confirmation below. Otherwise ask the user.
   - Never infer `REPO_PATH` from a path mentioned only as documentation / reference / context — accept only the path the user explicitly designates as the target.
   - Resolve `REPO_PATH` to an absolute path, then **AskUserQuestion**: "Migration target = `<abs path>` — correct? (confirm this is NOT the agents repo itself)"
     - "Yes, proceed with this path" → MI-2
     - "No, re-enter the correct path" → re-collect `REPO_PATH`, repeat MI-1
   - Run `node "$AGENTS_MAIN_ROOT/skills/migrate-issues/scripts/needs.js" --root "<REPO_PATH>"`; exit 0 means already migrated — report done and end.

MI-2. Preview + capture the snapshot.
   - Run `bash "$AGENTS_MAIN_ROOT/skills/migrate-issues/scripts/preview-and-capture.sh" "<REPO_PATH>"` as one standalone call — it runs the dry-run, mirrors it to stderr, and prints `export NAME=value` lines on stdout for `MIGRATE_ACK_UP_TO_ISSUE_N`, `MIGRATE_ACK_SELF_COUNT_AT_ACK` and `MIGRATE_SELF_REPO_DETECTED`.
   - Read those values from stdout and substitute them literally wherever the steps below name them.
   - Inspect `MIGRATE_SELF_REPO_DETECTED`:
     - `=1` → **AskUserQuestion**: "WARNING: target (`<REPO_PATH>`) is the agents repo itself. Proceed ONLY for an intentional agents-repo Phase 3 self-migration."
       - "Proceed as agents-repo Phase 3" → MI-3
       - "Abort and fix the path" → stop the skill
     - `=0` → MI-3

MI-3. Dry-run review gate. Called with `--dry-run` (e.g. from `/migrate --dry-run`): report the MI-2 preview and end the skill here — never enter MI-4.
   Otherwise **AskUserQuestion**: "Dry-run reviewed — proceed to History canary 1, or abort?"
   - Note in the question: if an existing-issues WARNING was shown, migrated issues permanently lose the "early issue numbers = history chronology" invariant.
   - "proceed" → MI-4
   - "abort" → stop the skill (no irreversible mutation yet)

### Live stages (MI-4 … MI-10)

Each stage below runs as its own command, formed as `<ACK> <BASE> <stage args>`:
- `<ACK>` = `MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N="$MIGRATE_ACK_UP_TO_ISSUE_N" MIGRATE_ACK_SELF_COUNT_AT_ACK="$MIGRATE_ACK_SELF_COUNT_AT_ACK"`
- `<BASE>` = `bash "$AGENTS_MAIN_ROOT/bin/github-issues/migration/orchestrate.sh" "$REPO_PATH"`

**Gate** (only where the table says "gate"): after the stage's issues appear at the printed URL, **AskUserQuestion** "proceed / abort".
- "proceed" → run the next stage's command.
- "abort" → stop the skill; resume later (see Resume) from a new session.

| Step | Stage | `<stage args>` | After stage |
|------|-------|----------------|-------------|
| MI-4 | History canary 1 | `--from-step 1 --stage canary-1` | gate → MI-5 |
| MI-5 | History canary 2 | `--from-step 2 --stage canary-2` | gate → MI-6 |
| MI-6 | History full | `--from-step 2 --stage full` | → MI-7 (no gate) |
| MI-7 | Todo canary 1 | `--from-step 3 --stage canary-1` | gate → MI-8 |
| MI-8 | Todo canary 2 | `--from-step 3 --stage canary-2` | gate → MI-9 |
| MI-9 | Todo full | `--from-step 3 --stage full` | → MI-10 (no gate) |
| MI-10 | Steps 4–6 | `--from-step 4` (continuous; no `--stage`) | done |

MI-10 note: Step 6 marks `migrate.issues` done in `.agents.json`, stages the allowlist (`.github/labels.yml`, `.github/ISSUE_TEMPLATE/`, `.gitignore`, `docs/todo.md`, `.agents.json`), commits `chore(migration): apply /migrate-issues Step 1/3 artifacts`, and pushes to `origin`. When `docs/` is a symlink to an external git repo, the docs entries are committed to the symlink-target repo in a separate commit.

## Resume (after failure or abort at stage N)

Resume in a new session:
- Re-run MI-2 (`preview-and-capture.sh`) for a fresh snapshot pair — accounts for issues already migrated.
- Re-run stage N's command (`<ACK> <BASE> <stage args>`) with the freshly captured snapshot vars.
- Re-dry-run is mandatory on resume; the Layer C gate fires on every live step.

## When archive files need explicit ordering

If `docs/history/` filenames sort in the wrong chronological order (e.g. `legacy-*.md` mixed with `2026-*.md`), pass the order explicitly with `--history-files` — comma-separated, relative to `docs/history/`; include the current `docs/history.md` as `../history.md`. Example: `orchestrate.sh "$REPO_PATH" --dry-run --history-files "legacy.md,legacy-agents.md,2026-agents.md,2026.md"`.

## agents repo (Phase 3)

history.md is already migrated → Step 2 skipped (idempotency). Steps 3–6 run.
