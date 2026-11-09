# Migration: docs/history.md + docs/todo.md → GitHub / GitLab Issues

Run `/migrate` — `/workflow-init` starts it on every session. It finds which of `/migrate-tracker`, `/migrate-issues` and `/migrate-tests` the target repo still needs, runs them, and records each one in the repo's `.agents.json`.
The canary-gated issue migration itself is `/migrate-issues` (`skills/migrate-issues/SKILL.md`); the label and board setup is `/migrate-tracker`.

This page keeps only the commands for manual recovery, when a run stopped part-way and the skills cannot be re-run as they are.

## Orchestrator steps

`bin/github-issues/migration/orchestrate.sh <repo_dir>` runs these steps in order. Step 2 must finish before Step 3, so history takes the early issue numbers and active TODOs the later ones.

| Step | What it does | Re-run |
|---|---|---|
| 1 | Label sync + `.github/ISSUE_TEMPLATE` copy | safe (idempotent) |
| 2 | Each `### entry` of `docs/history.md` and `docs/history/*.md` → one closed issue (`type:task` or `type:incident`, plus `status:migrated`) | skips entries recorded in `.migration-state.json` |
| 3 | Each non-empty `## section` of `docs/todo.md` → one open `type:task` issue; after the full stage `docs/todo.md` becomes an ID index | skips recorded entries |
| 4 | Projects v2 board + Content Date backfill (GitLab: skipped, no counterpart field) | safe |
| 5 | J-1 / J-2 sentinel comments on closed issues (GitLab: issue notes) | safe (skips issues that have the sentinel) |
| 6 | Mark `migrate.issues` done in `.agents.json`, commit the artifacts, push | safe |

Issue numbers are never reused: a create that ran cannot be undone. Always run `--dry-run` first and inspect the created issues between stages.

A fresh run stops with `WARNING: UNCOMMITTED_ALLOWLIST` when an allowlist file has uncommitted edits; commit or revert them first. Known limits: a resumed run (state file present) skips this check, and `.agents.json` is outside it, so Step 6 commits any pending `.agents.json` edit together with the migration.

## Manual recovery commands

| Situation | Command |
|---|---|
| Preview the history entries | `bash bin/github-issues/migration/preview-history.sh <repo_dir>` |
| Dry-run the whole migration | `bash bin/github-issues/migration/orchestrate.sh <repo_dir> --dry-run` |
| Resume a history stage | `bash bin/github-issues/migration/orchestrate.sh <repo_dir> --from-step 2 --stage canary-1\|canary-2\|full` |
| Resume a todo stage | `bash bin/github-issues/migration/orchestrate.sh <repo_dir> --from-step 3 --stage canary-1\|canary-2\|full` |
| Resume Steps 4–6 | `bash bin/github-issues/migration/orchestrate.sh <repo_dir> --from-step 4` |
| Content Date backfill alone | `MIGRATE_PROJECT_NUM=<n> MIGRATE_PROJECT_ID=<PVT_…> MIGRATE_FIELD_ID=<PVTF_…> bash bin/github-issues/migration/backfill-content-date.sh <repo_dir>` |
| Commit comments (sentinel) alone | `bash bin/github-issues/backfill-commit-comments.sh --target-checkout-root <repo_dir> [--dry-run\|--canary]` |
| Commit the `/migrate-issues` artifacts | `bash bin/github-issues/migration/commit-migration-artifacts.sh <repo_dir> --skill migrate-issues [--no-push]` |
| Commit `.agents.json` after `/migrate-tracker`, `/migrate-tests` or a `/migrate` recovery | `bash bin/github-issues/migration/commit-migration-artifacts.sh <repo_dir> --skill migrate-tracker\|migrate-tests\|migrate [--no-push]` |
| Record one migration done by hand | `node bin/repo-settings --root <repo_dir> --set-migrate tracker\|issues\|tests` |
| Repair a `.agents.json` that is unparsable, not an object, or fails the reader's validation (`MALFORMED=1`) | `node bin/repo-settings --root <repo_dir> --reset-malformed` (the original is kept as `.agents.json.malformed`) |

Starting the orchestrator with `--from-step N` warns about every earlier step that never ran; pass `--ack-skipped-steps` to skip them on purpose.
The live stages also need the dry-run snapshot variables that `skills/migrate-issues/scripts/preview-and-capture.sh` prints; `/migrate-issues` explains them.
