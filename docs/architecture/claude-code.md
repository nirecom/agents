# Claude Code Configuration

## Contents

1. [Workflow State Machine](claude-code/workflow.md) — 10-step workflow, state file schema, session ID flow, fail-safe behavior
2. [Session Sync](claude-code/session-sync.md) — cross-machine session history sync via private GitHub repo
3. [settings.json Design](claude-code/settings.md) — allow/deny rules, hook inventory
4. [Marker Bypass Contract](claude-code/marker-bypass-contract.md) — `WORKFLOW_OFF` / `WORKTREE_OFF` session markers, cross-hook honoring contract, exit-code semantics

## 5. EM Supervisor (Layer 1)

The EM (Engineering Manager) Supervisor is a three-layer architecture that collects
observations from skills and agents during a session and provides a foundation for
future automated triage.
Layer 1 (S-1, issue #228) is the only layer currently implemented; S-2 (#719) and
S-3 (#720) are placeholders.

**Why:** Layer 1 is a passive observation layer. It does not intervene in the workflow
or block any action. Skills and agents report findings they discover themselves;
severity judgment and remediation are deferred to Layer 2 and Layer 3.

**Reporting interface (`bin/supervisor-report`):**

Skills and agents submit findings via CLI:

```
node "$AGENTS_CONFIG_DIR/bin/supervisor-report" \
  --categories <cat1,cat2> --severity <error|warning|notice> \
  --detail "<description>" --reporter "<skill-name>" --session-id "$SID"
```

See `rules/supervisor-reporting.md` for category reference and usage guidance.

**Finding schema (per finding in `layer1.findings[]`):**

| Field | Type | Values |
|---|---|---|
| `categories` | string[] | `intent`/`outline`/`detail`/`workflow`/`code`/`test`/`security`/`performance`/`env`/`other` |
| `severity` | string | `error` / `warning` / `notice` |
| `detail` | string | free text |
| `reporter` | string | skill or agent name |
| `timestamp` | string | ISO 8601 |

**State file:** `<PLANS_DIR>/<session-id>-supervisor-state.json` (per-session, never global).
Defines the full 3-layer box: `layer1.findings[]`, `layer2: {}`, `layer3: {}`.
The file is directly inspectable for debugging; Layer 2 will read it for triage.

**No hooks registered in S-1.** Session-end aggregation is not actionable for the user
(work is already done) and the state file covers the debugging use case.
S-2 (#719) / S-3 (#720) will register hooks if asynchronous intervention is needed.

**Schema validation failures:** logged to `console.error` only — when the state file
cannot be written, appending a finding is structurally impossible, so no finding is
recorded for that case (known observation hole).

## 4. Test Iteration Workflow

TDD test writing uses a subagent (`mode: "auto"`) to run the write → run → fix loop
autonomously. This reduces user confirmations from O(N) (per-edit approval) to exactly 2:
(a) test case plan approval, (b) final test file review. The subagent is instructed to edit
only test files, never source code. See `write-tests` skill for the procedure.
