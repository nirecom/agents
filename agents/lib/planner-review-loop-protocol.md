## Risk-Signal File

When ANY of the following conditions apply, write ONE LINE of reason text to `<PLANS_DIR>/<session-id>-<PLANNER_TYPE>-risk-signal.txt` using the Write tool. Do NOT include any text in the plan draft itself:

1. The requirements in intent.md cannot be achieved by this plan (scope conflict or missing information).
2. The reviewer keeps raising the same concern without referencing source files (non-convergence risk).
3. An unresolved security concern exists (credential exposure, unsafe input handling, privilege escalation, etc.).

File content: one short reason line only (no markers, no prefix). If none of the conditions apply, do not create this file.
