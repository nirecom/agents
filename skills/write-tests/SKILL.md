---
name: write-tests
description: Plan and write test cases with high reasoning effort. Test iteration runs in a subagent to minimize confirmations.
model: sonnet
user-invocable: false
---

Write or update tests for the current task.

## Procedure

WT-0. Read the session facts once, before the pre-launch steps that consume them: `node "$AGENTS_CONFIG_DIR/bin/workflow/read-session-facts" --session "$SESSION_ID"`
   - `PLANS_DIR=` — substitute this absolute path for every `<PLANS_DIR>` below.
   - `GATE_CONFIRM_TESTS=` — the WT-5 pre-action gate (`ON` / `OFF` / `ERROR`).
   - `COMPLEXITY_LEVEL_write_tests=`, `COMPLEXITY_MODEL_write_tests=` and `COMPLEXITY_SIGNALS=` — the WT-6 level, model and signals.
   - If the command exits non-zero, or `PLANS_DIR=NONE`, stop — do not proceed with any step that uses `<PLANS_DIR>`; report via /supervisor-report; never construct a path like `NONE/<session-id>-...`.

WT-1. Read:
   - `rules/core-principles.md`
   - `skills/_shared/test-design.md`
   - `rules/test.md` — on-demand-only; never auto-injected, so this Read is mandatory
   For parser / regex / allowlist targets, apply the Table-Driven Tests pattern from `test-design/parser-regex-tests.md`.
WT-2. Identify which source file(s) need tests.
WT-3. **Enumerate call paths**: For each source file from WT-2, trace all integration
   paths it participates in — what calls it, what it calls, and what format/contract
   each boundary expects. For each boundary, list potential failure modes (wrong format,
   missing field, wrong type, unexpected value). These become integration-path error
   cases in WT-4.
WT-4. List all planned test cases by category (include call-path error cases from WT-3).
WT-5. Decide the destination of each planned case — append to an existing test file, or create a new one.
   - For each planned case, state its complete source set S (the `# Tests:` tokens the case protects).
   - Run `bash "$AGENTS_CONFIG_DIR/bin/find-tests-for-source.sh" --sources <comma-joined S>` with every distinct S in one call, repeating `--sources` (Bash, standalone command with timeout 600000; split rule in `skills/_shared/test-design/append-vs-new.md`; rows come back in query order; read-only, so `hooks/block-tests-direct.js` does not apply). On exit 4 or a tool timeout, HALT and surface the stderr.
   - Record each row's verdict/reason/target as the case group's destination. `append` is mandatory; the sole permitted new file when a target exists is the `size-hard-limit` case, per `skills/_shared/test-design/append-vs-new.md` — do not decide by eye.
   - If `GATE_CONFIRM_TESTS` is `ON` or `ERROR`, present the planned cases together with their destinations and wait for user confirmation before WT-6.
WT-6. **Determine the subagent's model**:
   - If `COMPLEXITY_LEVEL_write_tests` from WT-0 is not `NONE`, use `COMPLEXITY_MODEL_write_tests` as the model and `COMPLEXITY_SIGNALS` directly; skip the fallback below.
   - If `NONE` (fail-open for sessions without persisted evaluation):
     - Dispatch `subagent_type: complexity-judge` with: `intent.md` + `outline.md` + source files from WT-2–WT-3 + planned test cases from WT-4 (+ `detail.md` if present), so S1/S1b and stage-specific signals can be judged (rubric: `skills/_shared/judge-task-complexity.md`).
     - Write the raw subagent output to `<PLANS_DIR>/<session-id>-write-tests-judge-raw.txt` (Write tool — untrusted text via file only).
     - Run `bash "$AGENTS_CONFIG_DIR/bin/workflow/normalize-judge-signals" --raw-file "<PLANS_DIR>/<session-id>-write-tests-judge-raw.txt" --out "<PLANS_DIR>/<session-id>-write-tests-signals.txt"`.
     - Run `bash "$AGENTS_CONFIG_DIR/bin/workflow/derive-complexity-level" --stage write_tests --signals-file "<PLANS_DIR>/<session-id>-write-tests-signals.txt"` and use its `model=<alias>` line — never judge the level inline.
   - Emit in Claude text output (NOT Bash echo):
     > Model selected: **<model alias>** (signals: [comma-separated triggered signal IDs, or "none"])

WT-7. **Launch a subagent** (Agent tool, `mode: "default"`, `model: <model alias from WT-6>`) to autonomously:
   WT-7a. Write the test file(s).
   WT-7b. Run tests with timeout.
   WT-7c. Fix failures and re-run until green.
   WT-7d. Review test coverage against `skills/_shared/test-design.md` categories — fix gaps.
   WT-7e. Re-run tests until green.
   The subagent prompt MUST include these structured fields so verbose output stays in the subagent context:
   - `task_complexity_signals`: the `signals=` line from WT-6 verbatim (comma-separated IDs, or "none")
   - `source_files`: list of source file paths from WT-2
   - `planned_cases`: list of planned test cases from WT-4 — each entry states the source set it protects
   - `test_destinations`: one entry per case group, keyed by that group's complete source set — `append <path>` or `new`.
     Each source set's `new` verdict generates its own independent new file — one new file per source set.
     A `new` test file's path MUST be `tests/<category>/<file>` (category = first path segment of the source it protects; valid categories: hooks bin skills agents install tests) — never a flat `tests/<file>`; the commit gate rejects a newly-added flat test (#1834, #2392).
     Name a `new` file by a `supported` entry's `patterns` in `hooks/lib/test-language-registry.json`.
     A new test file MUST source its language's registry `helperLibrary` when one is named (bash: `tests/lib/harness.sh`) — `bin/check-test-frontmatter.sh` rejects new files without it.
     If `# Tests:` lists 2 or more paths, every case MUST be wrapped in `case_begin`/`case_end` markers (see `tests/lib/harness.sh`); `bin/check-case-markers.sh` flags multi-path files without markers as HIGH.
     On `append`: never rewrite the target's `# Tests:` line; `# Tags:` may only be added to.
     `append` is mandatory when the verdict is `append`; `skills/_shared/test-design/append-vs-new.md` is the SSOT for when a new file is warranted instead.
   The subagent prompt MUST instruct: edit only test files, never modify source code.
   The subagent prompt MUST instruct: Read `rules/shell-commands.md` before the first Bash command, or before writing a file — general-purpose dispatch does not inherit auto-injected rules.
   The subagent prompt MUST instruct: Read `rules/user-escalation.md` before any system-state-changing command — general-purpose dispatch does not inherit auto-injected rules.
   The subagent prompt MUST instruct: Read `rules/coding.md` (the hub — on-demand-only, so it does not reach you otherwise) and `rules/coding/<lang>.md` for each language present, before the first Edit.
   The subagent prompt MUST instruct: for Bash, PowerShell, JSON, or YAML test files (no `rules/coding/<lang>.md` B-layer exists for these), apply the A-layer language essence from `skills/write-code/SKILL.md`'s "A-layer language essence" section before the first Edit.
   The subagent prompt MUST instruct: Read `rules/test.md` before writing or running tests — on-demand-only, so it does not reach you otherwise; general-purpose dispatch does not inherit auto-injected rules.
   Note: the Stop-guard silence during dispatch is automatic (PostToolUse marks the step `in_progress`). Do not emit `NEXT_STEP_PAUSE`.
   The subagent prompt MUST also include: "NEVER present diffs for approval. NEVER wait for user confirmation. Edit and run autonomously until tests pass."
   - (Optional) Follow `agents/lib/nfr-severity-calibration.md` to obtain the PROJECT NFR block and use it as a test constraint when relevant.

While the subagent runs, the orchestrator MAY run the WT-8 `CONFIRM_TESTS` gate probe (`bin/confirm-off`) — never read the test files the subagent is still writing (SC-W — `skills/_shared/subagent-concurrency.md`).

WT-8. Present the final test file content to the user for review — gated by **CONFIRM_TESTS gate (post-action review)**:
   `bash -c 'cd "$AGENTS_CONFIG_DIR" && bash "$AGENTS_CONFIG_DIR/bin/confirm-off" CONFIRM_TESTS on'`
   - stdout `OFF`: skip WT-8; proceed directly to Completion (no user wait).
   - stdout `ON` or `ERROR`: present the test file content.

## Completion

After completing this skill:
The order below is load-bearing — do not reorder.
1. Stage the test files first: `git add tests/` — the evidence gate is fail-closed, so an unstaged tests/ makes the `next-step --advance` call below reject the completion.
2. From the linked worktree's CWD, as a single standalone Bash command: `node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --advance --step write_tests --complete --next`
3. Do NOT prefix that `next-step --advance` call with `cd "$AGENTS_CONFIG_DIR" &&` — the CLI resolves the evidence repo from the Bash process's own CWD via `git rev-parse --show-toplevel` (`resolveTrustedRepoDir()` in `hooks/workflow-state/record-step-verdict.js`), so a `cd` points it at the main agents worktree and the completion is rejected fail-closed.
4. Follow the returned `ACTION` / `NEXT_SKILL` / `NEXT_HINT` per CLAUDE.md.
5. `/review-tests` auto-backfills write_tests when evidence exists; the `next-step --advance` call is the primary door.
6. Run tests (validation only — this does not satisfy the run_tests workflow step).

If tests are genuinely not needed for this change:
1. Run: `echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: {reason}>>"`, then record it as `--class E --step write_tests --key write-tests:not-needed`, per `skills/_shared/handoff-record.md`.
2. Run tests (validation only — this does not satisfy the run_tests workflow step).

When WT-6 took the `NONE` fallback, record it as `--class D --step write_tests --key write-tests:model-fallback`, per `skills/_shared/handoff-record.md`.

## Rules

- Report observations via /supervisor-report (trigger conditions: rules/supervisor-reporting.md).
