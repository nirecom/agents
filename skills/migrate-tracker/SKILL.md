---
name: migrate-tracker
description: Sync the target repo's labels and create/link its issue board (GitHub Projects v2 or a GitLab issue board), then record migrate.tracker in .agents.json.
user-invocable: true
---

Initialize a target repo's issue tracker: sync its label set, create/link its board, and record the result.

## Scope

- Sync the target repo's label set (from `agents/.github/labels.yml`) and initialize its board.
- Cross-repo aware: the target repo may differ from the CWD repo.
- GitHub uses `gh` + Projects v2; GitLab (`HOST=gitlab`) uses `glab` labels and an issue board with label lists; Content Date has no GitLab counterpart and is skipped.

## Pre-flight

- Read `rules/github-issues.md` — on-demand-only, never auto-injected; it owns the Labels section (`sync-labels.sh`, `.github/labels.yml`) and the Projects v2 `project` scope requirement.
- `AGENTS_MAIN_ROOT` must be set.
- GitHub: `gh` must be authenticated with the `project` scope; if absent, tell the user to run `gh auth refresh -s project` and stop. GitLab: `glab` must be authenticated.
- `HOST=unknown` (neither github.com nor GitLab): exit 0 with a notice; for self-managed GitLab, tell the user to set `GITLAB_HOSTNAME` in the agents `.env` or the target repo's `.env.local` and rerun.

## Procedure

MT-1. Resolve the target. Called from `/migrate`: take `ROOT` / `HOST` as given and ask nothing. Otherwise AskUserQuestion (`metadata.source=migrate-tracker.target-select`):
- `current`: `ROOT` = `git rev-parse --show-toplevel` of the CWD; `TARGET_REPO` from its origin.
- `other`: ask for `OWNER/REPO` (GitLab also takes `GROUP/.../PROJECT`, which needs the local checkout) and its local checkout path, or "no local checkout" (then `ROOT` stays unset).
- When `ROOT` is set, run `node "$AGENTS_MAIN_ROOT/skills/migrate-tracker/scripts/needs.js" --root "<ROOT>"`; exit 0 means already done — report success and end.

MT-2. Sync labels (no confirmation — automatic): run `run-issue-setup.sh --step labels --repo "$TARGET_REPO"` (add `--root "<ROOT>"` whenever `ROOT` is set, in every step).

MT-3. Check the board: run `run-issue-setup.sh --step check-project --repo "$TARGET_REPO"` → rc=0 present / rc=1 absent or incomplete (GitLab: a status:* list missing).

MT-4. When the board is absent or incomplete, AskUserQuestion (`metadata.source=migrate-tracker.board-create`):
- `create`: run `run-issue-setup.sh --step ensure-project --repo "$TARGET_REPO"`; on a non-zero exit, show its stderr and end without MT-5 (the next `/migrate` asks again).
- `skip`: tell the user a manual link is required and that the next session's `/migrate` asks again; end without MT-5.

MT-5. Record done (only when `ROOT` is set): run `run-issue-setup.sh --step record-done --repo "$TARGET_REPO" --root "<ROOT>"` (plus `--no-push` / `--dry-run`). It re-checks the board and commits `.agents.json`; rc=2 means `ROOT`'s origin is not `TARGET_REPO`, rc=1 means no complete board — nothing is written in either case.

MT-6. Report the outcome. A skip or "no local checkout" is not done: say the next `/migrate` will ask again.

## Dry run

- With `--dry-run`, pass `--dry-run` to every `run-issue-setup.sh` call; labels, ensure-project and record-done then only print their plan lines.
- With `--dry-run`, run MT-4 without AskUserQuestion: an absent board shows the ensure-project plan line. <!-- askuser-none -->
- Report the plan lines as what a real run would do; nothing is synced, created, written or committed.

Backend script path: `$AGENTS_MAIN_ROOT/skills/migrate-tracker/scripts/run-issue-setup.sh`.
