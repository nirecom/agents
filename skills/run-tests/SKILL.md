---
name: run-tests
description: Invokes the test-runner subagent and emits the run_tests workflow sentinel. Used by Workflow Step 6.
tools: Agent, Bash
model: sonnet
user-invocable: false
---

Run the project test suite via the test-runner subagent and emit the workflow sentinel.

## Procedure

1. **Resolve merge-base** (fallback chain):
   - Try: `git fetch origin main --no-tags 2>/dev/null`, then `merge_base=$(git merge-base origin/main HEAD)`.
   - If fetch fails or `origin/main` absent: `merge_base=$(git merge-base main HEAD)`.
   - If local `main` absent (shallow clone / detached): `merge_base=HEAD~1`; emit warning `[run-tests] merge-base fallback: HEAD~1 (no main ref)`.
   - If `HEAD~1` unavailable (root commit): emit `[run-tests] cannot resolve merge-base; skipping selection` and treat as empty selection (go to step 5 empty-selection policy).

2. **Tier 1 — mechanical stem match.**
   `tier1_tests=$(bin/select-tests.sh "$merge_base")`
   Filename stem substring match only. No frontmatter reading.

3. **Tier 2 — LLM semantic match.**
   For each `tests/*.sh` not in `tier1_tests` and not under `tests/_archive/`:
   - Read `# Tests:` and `# Tags:` lines (single-line, within `head -n 10`).
   - Compare against `git diff --name-only "$merge_base"...HEAD` and diff body.
   - Add if: `# Tests:` path overlaps a changed file, OR `# Tags:` token semantically matches a changed subsystem.
   - Cap: max 20 Tier 2 additions per run.

4. **Tier 3 — default skip.**
   All remaining tests are skipped unless `RUN_ALL_TESTS=1` or `--all` is passed explicitly.

5. **Empty-selection policy (no silent `--all` fallback).**
   If Tier 1 + Tier 2 = 0 tests:
   - Docs-only change (all changed files match the docs allowlist): log `[run-tests] docs-only change; skipping tests` and skip.
   - Otherwise: log `[run-tests] no tests matched; user judgment required` and ask the user: skip / `--all` (explicit opt-in) / specify tests. Never auto-fallback to `--all` — that recreates the #673 hang.

6. **Run tests.**
   Pass the final list as positional args to `tests/run-all.sh`. Use `tests/run-all.sh --all` only when the user explicitly opts in. Never pass `auto-detect`.

7. **Invoke test-runner subagent** with the resolved command and working directory. Return structured YAML.

8. **Parse the YAML** block returned by the agent.

9. **Emit sentinel** as a separate Bash call:
   - `status: pass` → `echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>"`
   - `status: fail | timeout | runner-error` → `echo "<<WORKFLOW_MARK_STEP_run_tests_pending>>"`

10. If status is not `pass`, surface: `summary` / `failing_tests` / `log_tail`.

## Rules

- Test selection is this skill's responsibility, not test-runner's. Never pass `auto-detect`.
- Always pass an explicit list or `--all` to `tests/run-all.sh`.
- Empty selection on non-doc changes requires user confirmation; no silent `--all` fallback.
- Never modify source code or test files.
- Never retry on failure (Phase 1 only).
