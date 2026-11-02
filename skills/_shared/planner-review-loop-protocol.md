## Risk-Signal File

Outline and detail planners only: when ANY of the following conditions apply, run `node "$AGENTS_MAIN_ROOT/bin/record-risk-signal" --session <session-id> --planner <PLANNER_TYPE> --reason "<one line>"`. Do NOT include any text in the plan draft itself:

1. The requirements in intent.md cannot be achieved by this plan (scope conflict or missing information).
2. The reviewer keeps raising the same concern without referencing source files (non-convergence risk).
3. An unresolved security concern exists (credential exposure, unsafe input handling, privilege escalation, etc.).

`--reason`: one short line only (no markers, no prefix). If none of the conditions apply, do not run it.
