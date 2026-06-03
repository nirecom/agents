# Claude Code Configuration

## Contents

1. [Workflow State Machine](claude-code/workflow.md) — 10-step workflow, state file schema, session ID flow, fail-safe behavior
2. [Session Sync](claude-code/session-sync.md) — cross-machine session history sync via private GitHub repo
3. [settings.json Design](claude-code/settings.md) — allow/deny rules, hook inventory
4. [Marker Bypass Contract](claude-code/marker-bypass-contract.md) — `WORKFLOW_OFF` / `WORKTREE_OFF` session markers, cross-hook honoring contract, exit-code semantics

## 5. EM Supervisor (Layer 1)

The EM (Engineering Manager) Supervisor is a three-layer architecture that monitors
sessions for structural and semantic compliance without blocking the user's flow.
Layer 1 (S-1, issue #228) is the only layer currently implemented; S-2 (#719) and
S-3 (#720) are placeholders.

**Why:** Hooks run synchronously at tool boundaries. Layer 1 performs only regex-based
structural checks that complete well within the 5-second hook timeout and require no
LLM calls. Semantic judgment (Layer 2) and strategic review (Layer 3) run asynchronously
on a separate schedule.

**What Layer 1 checks (PostToolUse, `hooks/supervisor-layer1.js`):**
- `plan_artifact` — intent.md exists for the current session under `<PLANS_DIR>/`
- `scope_keyword` — ASCII keywords from intent.md `## Scope` appear in `git diff --cached`
- `non_goal_keyword` — ASCII keywords from `## Confirmed non-goals` appear in staged diff
- `sentinel` — sentinel-shaped literals in Bash tool_input.command or tool_response

**State file:** `<PLANS_DIR>/<session-id>-supervisor-state.json` (per-session, never global).
Layer 1 defines the full 3-layer box structure: `layer1.findings[]` (fully defined),
`layer2: {}` and `layer3: {}` (additionalProperties: true, for S-2/S-3 extension).

**Intervention model:** Layer 1 emits `additionalContext` warnings inline at the
PostToolUse boundary only. `decision: "block"` is never issued. No Stop hook is
registered in S-1 — session-end aggregation would not be actionable for the user
(work is already done) and the state file is directly inspectable for debugging.
S-2 (#719) / S-3 (#720) will register their own Stop hook if asynchronous severity
gating is needed.

**Schema validation failures:** logged to `console.error` only — when the state file
cannot be written, appending a finding is structurally impossible, so no finding is
recorded for that case (known observation hole).

## 4. Test Iteration Workflow

TDD test writing uses a subagent (`mode: "auto"`) to run the write → run → fix loop
autonomously. This reduces user confirmations from O(N) (per-edit approval) to exactly 2:
(a) test case plan approval, (b) final test file review. The subagent is instructed to edit
only test files, never source code. See `write-tests` skill for the procedure.
