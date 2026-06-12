# Claude Code Configuration

## Contents

1. [Workflow State Machine](claude-code/workflow.md) — 10-step workflow, state file schema, session ID flow, fail-safe behavior
2. [Session Sync](claude-code/session-sync.md) — cross-machine session history sync via private GitHub repo
3. [settings.json Design](claude-code/settings.md) — allow/deny rules, hook inventory
4. [Marker Bypass Contract](claude-code/marker-bypass-contract.md) — `WORKFLOW_OFF` / `WORKTREE_OFF` session markers, cross-hook honoring contract, exit-code semantics
5. [settings.json Drift Prevention](#6-settingsjson-drift-prevention) — layered defense: git hooks + session-start backstop

## 5. EM Supervisor (Layer 1)

The EM (Engineering Manager) Supervisor is a three-layer architecture that collects
observations from skills and agents during a session and provides a foundation for
future automated triage.
Layer 1 (S-1, issue #228) is the only layer currently implemented; S-2 (#719) and
S-3 (#720) are placeholders.

**Why:** Layer 1 is a passive observation layer. It does not intervene in the workflow
or block any action. Three reporting paths feed findings into the state file:
(A) hooks auto-report block events; (B) skills self-report fallback/degradation paths;
(C) session-close runs a retrospective pass before the Final Report.
Severity judgment and remediation are deferred to Layer 2 and Layer 3.

**Hook auto-report (`hooks/lib/supervisor-emit.js`):**

A fail-open facade over `appendFinding()` with typed emitters:
`reportBlock(hook, command, sessionId)`, `reportFallback(skill, fallbackName, sessionId)`,
`reportSentinel(kind, reason, sessionId)`, `reportRetrospective(observation, sessionId)`.
Each function swallows errors silently so hook block/allow decisions are unaffected.
`enforce-worktree.js`, `workflow-gate.js`, and `enforce-issue-close.js` call `reportBlock()`
at every block exit; `enforce-override-handlers.js` calls `reportSentinel()` on `_OFF` sentinels.

**Reporting interface (`bin/supervisor-report`):**

Skills and agents submit findings via CLI (`--session-id` auto-resolves when omitted):

```
node "$AGENTS_CONFIG_DIR/bin/supervisor-report" \
  --categories <cat1,cat2> --severity <error|warning|notice> \
  --detail "<description>" --reporter "<skill-name>"
```

Auto-resolve precedence: `--session-id` flag → `resolveSessionId()` in
`hooks/lib/workflow-state.js` (CLAUDE_ENV_FILE → CLAUDE_SESSION_ID env →
WORKTREE_NOTES.md in CWD → WORKTREE_NOTES.md via git common-dir →
JSONL scan) → usage error.
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

**Schema validation failures:** logged to `console.error` only — when the state file
cannot be written, appending a finding is structurally impossible, so no finding is
recorded for that case (known observation hole).

## 4. Test Iteration Workflow

TDD test writing uses a subagent (`mode: "auto"`) to run the write → run → fix loop
autonomously. This reduces user confirmations from O(N) (per-edit approval) to exactly 2:
(a) test case plan approval, (b) final test file review. The subagent is instructed to edit
only test files, never source code. See `write-tests` skill for the procedure.


## 6. settings.json Drift Prevention

`~/.claude/settings.json` is a copy-deployed file assembled by `install/assemble-settings.js`
from `agents/settings.json` (base) + `agents/settings-extension.json` (extension).
It cannot be a symlink because the extension contains host-private absolute paths.

**Problem:** When `settings.json` gains new hook registrations or permission entries after
the assembled file was last generated, the assembled copy becomes stale. Stale permission
entries cause workflow sessions to stall on blocked tool calls or absent sentinels.

**Defense layers** (all delivered via `core.hooksPath = agents/hooks/`; no installer change needed):

| Layer | Hook | Trigger | Action |
|---|---|---|---|
| Proactive | `hooks/post-merge` | git merge / pull changes `settings.json` or `settings-extension.json` | Auto-reassemble `~/.claude/settings.json` |
| Proactive | `hooks/post-checkout` | Branch switch changes those files | Auto-reassemble |
| Backstop | `hooks/session-start.js` + `hooks/lib/settings-drift.js` | Every session start | Detect missing entries; inject `WARNING` into `additionalContext` |

**Repo guard:** Both git hooks compare `git rev-parse --show-toplevel` against the agents
root to fire only inside the agents repo (not in every repo on the machine that uses
`core.hooksPath`). All hooks are fail-open — any assembler error exits 0.

**Drift detection algorithm** (`hooks/lib/settings-drift.js`):
- Permissions (`allow`, `deny`, `ask`, `additionalDirectories`): subset check — every entry
  present in base+ext must exist in the assembled file.
- Hooks: multiset count — the same `matcher` string can appear multiple times (e.g., one
  per PreToolUse command), so a Map-based count is used instead of a Set.

**Source of truth:** The assembler always reads from the agents **main worktree**'s
`settings.json` (`__dirname`-relative from `hooks/lib/`). Linked worktrees are not used
as assembler input.
