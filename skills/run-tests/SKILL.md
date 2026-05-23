---
name: run-tests
description: Invokes the test-runner subagent and emits the run_tests workflow sentinel. Used by Workflow Step 6.
tools: Agent, Bash
model: sonnet
user-invocable: false
---

Run the project test suite via the test-runner subagent and emit the workflow sentinel.

## Procedure

1. Infer the test command and working directory from context:
   - Test command: use the project's known command; fall back to `"auto-detect"`.
   - Working directory: current project directory (or explicit worktree path if in a linked worktree).

2. Invoke the test-runner subagent:
   ```
   Agent({
     subagent_type: "test-runner",
     model: "sonnet",
     prompt: "Run the project test suite.\nTest command: <command or 'auto-detect'>\nWorking directory: <cwd>\nTimeout: 120s\nReturn the structured YAML summary per your output contract."
   })
   ```
   Model: default `sonnet`. Escalate to `opus` only when the test surface is unusually large
   or failure-summary parsing demands architectural reasoning.

3. Parse the YAML block returned by the agent.

4. Emit the sentinel as a **separate Bash call** (no pipes, no `&&`, no redirection):
   - `status: pass` → `echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>"`
   - `status: fail | timeout | runner-error` → `echo "<<WORKFLOW_MARK_STEP_run_tests_pending>>"`

5. If status is not `pass`, surface to the user: `summary` / `failing_tests` / `log_tail`.

## Rules

- The fail-path sentinel is mandatory — it overwrites stale `complete` state so a failing
  build cannot pass the commit gate from a prior successful run.
- Direct Bash test runs still work — PostToolUse hook (`workflow-run-tests.js`) auto-marks
  based on exit code, retaining backward compatibility.
- Never modify source code or test files.
- Never retry on failure (Phase 1 only).
