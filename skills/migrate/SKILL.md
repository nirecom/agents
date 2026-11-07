---
name: migrate
description: Repo migration hub. Runs whichever of /migrate-tracker, /migrate-issues and /migrate-tests the target repo still needs, judged by bin/migrate-needs.
user-invocable: true
---

Hub skill that brings a target repo up to the agents workflow: issue tracker, issue history and the `.agents.json` tests section.
It is the only place that decides from `bin/migrate-needs` what to run; the sub-skills hold the judgments, the hub holds no criterion.

## Inputs

- `ROOT`: the target repo's checkout root (default: `git rev-parse --show-toplevel` of the CWD). `/workflow-init` passes it.
- Options forwarded verbatim to every sub-skill: `--no-push`, `--dry-run`.
- Pass `ROOT` and the `HOST` from MG-1 to each sub-skill, so none of them asks for the repo again.

## Procedure

MG-1. Read: run `node "$AGENTS_MAIN_ROOT/bin/migrate-needs" --root "<ROOT>"` as one standalone call; keep `NEEDED`, `UNCOMMITTED`, `UNPUSHED`, `HOST` and `MALFORMED` from its stdout.
   A non-zero exit goes to "On failure".
   When `MALFORMED=1` (the settings file is not a JSON object), ask once through AskUserQuestion before MG-2:
   - "Reset (recommended)": run `node "$AGENTS_MAIN_ROOT/bin/repo-settings" --root "<ROOT>" --reset-malformed` as one standalone call, then re-run MG-1; the original is kept as `.agents.json.malformed`.
   - "Skip for this session": write nothing, print `MIGRATE_RESULT=skipped` and end.
   With `--dry-run`, do not reset and ask nothing: report that it would run `--reset-malformed`, then go on to MG-2.
   "Settled" (judged in MG-3) means `UNCOMMITTED=0` and either `UNPUSHED=0` or `--no-push` was given.

MG-2. Run: when `NEEDED` is empty, go to MG-3 asking nothing.
   When `NEEDED` lists a skill, ask through AskUserQuestion with two choices:
   - "Run now (recommended)": invoke each skill in `NEEDED` in its order with `ROOT` / `HOST` / options; stop at the first failure and go to "On failure". Then go to MG-3.
   - "Skip for this session": write no state, print `MIGRATE_RESULT=skipped` and end.
   The skip choice's description names what silently fails until the migration runs: the label step in clarify_intent, the WIP record, the Projects v2 registration of an in-progress issue, and the session close board update.
   It also says tests stay blocked: the run_tests check refuses a repo with no valid tests section.

MG-3. Settle: run `bash "$AGENTS_MAIN_ROOT/skills/migrate/scripts/settle.sh" "<ROOT>"` (plus `--no-push` / `--dry-run` when given) and print its `MIGRATE_RESULT` line (`MIGRATE_RESULT=ok` or `MIGRATE_RESULT=skipped`) as is. Ask nothing.
   A non-zero exit goes to "On failure".

## On failure

Show the failing output (`bin/migrate-needs`, sub-skill, or settle.sh), then ask through AskUserQuestion:
- "Skip for this session": print `MIGRATE_RESULT=skipped`; its description names the impacts by pointing at MG-2.
- "Stop": print `MIGRATE_RESULT=failed`.

## Rules

- Skip exits exist only in MG-1 (`MALFORMED=1`), MG-2 and On failure; never record a skip as done, so the next session's `/migrate` asks again.
- Print exactly one `MIGRATE_RESULT` line per run; its three values are the contract with `/workflow-init`.
- Commit recovery is a named exception in settle.sh: every needs.js already says done, so the missing commit or push is git state; it stages `.agents.json` only.
- Writes land in `ROOT`'s main worktree; each sub-skill commits right after writing through `commit-migration-artifacts.sh`, which pushes to the current branch unless `--no-push` is passed.
- Manual recovery commands: `docs/ops/migration-from-todo.md`.
