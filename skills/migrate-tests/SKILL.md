---
name: migrate-tests
description: Write the target repo's .agents.json tests section (layout, harness, case markers) from what its tests/ already holds, and commit it.
user-invocable: true
---

Records how the target repo's tests are laid out, so the test gates and `tests/run-all.sh` can run there.

## Inputs

- `ROOT`: the target repo's checkout root. `/migrate` passes it; run directly, use `git rev-parse --show-toplevel` of the CWD.
- `--no-push`: forwarded to the commit.
- `--dry-run`: run MTS-1 and MTS-2, show the section MTS-3 would write, and skip MTS-3; nothing is written or committed.

## Procedure

MTS-1. Run `node "$AGENTS_MAIN_ROOT/skills/migrate-tests/scripts/needs.js" --root "<ROOT>"`; exit 0 means the tests section is already valid — report done and end.
MTS-2. Run `node "$AGENTS_MAIN_ROOT/skills/migrate-tests/scripts/detect.js" --root "<ROOT>"`, read its JSON proposal and confirm through AskUserQuestion (`metadata.source=migrate-tests.proposal-confirm`): `categorization` among `candidates` (first one recommended) with its `categories` / `supportDirs` from `sections[<choice>]`, then `testHarness` / `caseMarker` as proposed (off whenever an existing test does not source the agents harness).
MTS-3. Run `bash "$AGENTS_MAIN_ROOT/skills/migrate-tests/scripts/apply-section.sh" "<ROOT>" '<json>'` (plus `--no-push`), where `<json>` is `sections[<choice>]` with the confirmed answers applied; then report the written section and the commit to the user.
   Exit 3 means the settings file is not JSON or does not hold an object: confirm through AskUserQuestion (`metadata.source=migrate-tests.reset-malformed`; "Reset, keeping the original as `.agents.json.malformed`" / "Stop"); on reset, run `node "$AGENTS_MAIN_ROOT/bin/repo-settings" --root "<ROOT>" --reset-malformed`, then re-run the same write.
   Any other non-zero exit: show the error and stop.

## Rules

- Never write the section without the MTS-2 confirmation.
- Schema and state meanings: `docs/architecture/claude-code/repo-settings-file.md`.
