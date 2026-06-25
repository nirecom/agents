# Claude Code Configuration

## Contents

1. [Workflow State Machine](claude-code/workflow.md) — 10-step workflow, state file schema, session ID flow, fail-safe behavior
2. [Session Sync](claude-code/session-sync.md) — cross-machine session history sync via private GitHub repo
3. [settings.json Design](claude-code/settings.md) — allow/deny rules, hook inventory
4. [Marker Bypass Contract](claude-code/marker-bypass-contract.md) — `WORKFLOW_OFF` / `WORKTREE_OFF` session markers, cross-hook honoring contract, exit-code semantics
5. [settings.json Drift Prevention](#6-settingsjson-drift-prevention) — layered defense: git hooks + session-start backstop

## 5. EM Supervisor (alert/audit two-mode design)

**Canonical shared contract:** This section is the SSOT for JD skeleton, arming protocol, output field conventions, and agent file names. Both `agents/supervisor.md` (alert mode) and `agents/supervisor-audit.md` (audit mode) reference this section — do not duplicate design rationale in those files.

The EM (Engineering Manager) Supervisor is a single logical supervisor with two physical agent files, differentiated by information scope. Layer 1 (S-1, #228), alert mode (S-2, #719), and audit mode (S-3, #720) are implemented.

**Physical file design:** `agent.model` is a single value per file, so model tiering (alert→Sonnet, audit→Opus) requires two files. This is an implementation constraint, not an architectural split — the two files express one supervisor contract at different information scopes.

### Alert mode (S-2, #719)

Alert mode (`agents/supervisor.md`, model: Sonnet) handles C1/C2/C3 triggers. Information scope: current session turn. Three triggers arm `alert_armed_at`: C1 sentinel hang, C2 scheduled-review, C3 off-proposal (WORKTREE_OFF or WORKFLOW_OFF).

### Audit mode (S-3, #720)

Audit mode (`agents/supervisor-audit.md`, model: Opus) handles stage-boundary and severity-threshold triggers. Information scope: all stages + finding history. Two triggers arm `audit_armed_at`: (a) stage-boundary — `<<WORKFLOW_CONFIRM_{INTENT|OUTLINE|DETAIL}>>` sentinel in the most recent assistant turn; (b) severity-threshold — `alert.cumulative_severity` reaches `AUDIT_SEVERITY_THRESHOLD` (`error`).

Audit produces a single verdict (`CONTINUE` / `WARN` / `BLOCK`) recorded in `state.audit.audit_verdict`, written via `bin/supervisor-write-audit-verdict`. The verdict is combined with any concurrent alert verdict by `hooks/lib/supervisor-guard/arbitrate.js` (rule table: BLOCK wins, WARN aggregates, otherwise allow) before the Stop hook emits a single block-or-allow decision.

**Lifecycle (two-phase):** *arm* — Stop hook detects trigger, writes `audit_phase=pending` + `audit_armed_at` + `audit_cause`, then blocks with a prompt to invoke the audit agent. *surface* — the agent runs, writes `audit_phase=done` + `audit_verdict`; the next Stop event reads the verdict, surfaces it through `arbitrate()`, then clears `audit_phase=null` so the next stage boundary can re-arm. Anti-thrash: `incrementAuditRetryCount` auto-freezes the session after `AUDIT_RETRY_THRESHOLD` (2) consecutive failures. Alert and audit freeze independently.

**Why:** Layer 1 is a passive observation layer. It does not intervene in the workflow or block any action. Three reporting paths feed findings into the state file: (A) hooks auto-report block events; (B) skills self-report fallback/degradation paths; (C) session-close runs a retrospective pass before the Final Report. Alert mode is an active review: the `supervisor-guard.js` Stop hook fires a `decision:block` when findings are present and `alert_phase` is not `done`/`frozen`, invoking the alert supervisor. At most one alert review runs per session. Audit mode triggers on stage boundaries and severity-threshold, providing cross-stage strategic oversight.

**Supervisor vs codex differentiation:** The supervisor does NOT re-adjudicate technical correctness — codex (a different provider) handles that. The supervisor reads codex verdict as input and assesses intent/trajectory alignment using information codex does not have access to (plan artifacts, session history, rules).

**Block message format (`hooks/lib/supervisor-report-format.js`):**

Pure-function module; no I/O or side effects. Exports:
`formatCumSevErrorReason(findings, sessionId, workflowSessionId, supervisorPath)` for the cumSev=error branch.
`formatL2ArmedReason(cause, sessionId, workflowSessionId, supervisorPath, stateFilePath)` for the alertArmedAt/hang branch.
`formatWorktreeOffProposalReason(...)` for C3 block reason.

**Hook auto-report (`hooks/lib/supervisor-emit.js`):**

A fail-open facade over `appendFinding()` with typed emitters:
`reportBlock(hook, command, sessionId)` — severity: `error` (hook blocked an operation).
`reportFallback(skill, fallbackName, sessionId)` — severity: `warning` (degraded path taken).
`reportSentinel(kind, reason, sessionId)` — severity: `warning` (escape-hatch sentinel).
`reportRetrospective(observation, sessionId)` — severity: `notice` (session-close audit trail).

**Arming threshold:** `ensureAlertScheduled(state, sessionId, finding)` — when `finding.severity === "notice"`, alert is NOT armed. Only `severity >= warning` triggers arming. This ensures `reportBlock` (error) and `reportFallback` (warning) arm the supervisor, while `reportRetrospective` (notice) does not.

**Reporting interface (`bin/supervisor-report`):**

Skills and agents submit findings via CLI (`--session-id` auto-resolves when omitted):

```
node "$AGENTS_CONFIG_DIR/bin/supervisor-report" \
  --categories <cat1,cat2> --severity <error|warning|notice> \
  --detail "<description>" --reporter "<skill-name>"
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
Defines the full structure: `layer1.findings[]`, `alert: { … }`, `audit: {}`.
The file is directly inspectable for debugging.

**`alert` fields:**

| Field | Type | Description |
|---|---|---|
| `alert_phase` | `null`/`"pending"`/`"done"`/`"frozen"` | Lifecycle SSOT: null=never scheduled, pending=armed, done=ran this session, frozen=resumable suspended (new findings with severity >= warning re-arm alert mode from this state; `frozen→pending` re-arm resets `alert_retry_count`) |
| `alert_armed_at` | ISO string or null | Timestamp when alert was armed; null when phase is done/frozen |
| `alert_cause` | string or null | Trigger label: `"C1 sentinel hang"`, `"C2 scheduled-review"`, `"C3 worktree-off proposal"`, or `"C3 workflow-off proposal"`; co-cleared when `alert_armed_at` is nulled |
| `last_run_at` | ISO string or null | Timestamp of last alert execution |
| `cumulative_severity` | string or null | Highest severity across alert findings |
| `alert_retry_count` | integer | Consecutive failure count; frozen after `ALERT_RETRY_THRESHOLD` (2) |
| `findings_surfaced_at` | ISO string or null | When findings were surfaced in Final Report |
| `alert_eligible_phase` | string or null | `"post_final_report_window"` when late-phase eligibility set (#997) |
| `findings[]` | Finding[] | Alert findings; each finding carries an optional `status` field (`"draft"` / `"confirmed"`); `idx` is a stable integer key |

**`audit` fields:**

| Field | Type | Description |
|---|---|---|
| `audit_phase` | `null`/`"pending"`/`"in_progress"`/`"done"`/`"frozen"` | Lifecycle SSOT |
| `audit_verdict` | string or null | `"CONTINUE"` / `"WARN"` / `"BLOCK"` |
| `audit_armed_at` | ISO string or null | Timestamp when audit was armed |
| `audit_cause` | string or null | Trigger: `stage-boundary:CONFIRM_<STAGE>` or `severity-threshold:<level>` |
| `audit_last_run_at` | ISO string or null | Timestamp of last audit execution |
| `audit_retry_count` | integer | Consecutive failure count; frozen after `AUDIT_RETRY_THRESHOLD` (2) |
| `findings[]` | Finding[] | Audit findings |

**Alert lifecycle and gate-yield:** `writeAlertState()` refuses to set `alert_armed_at` when `alert_phase` is `done` or `frozen` (at-most-1 guarantee). `ensureAlertScheduled()` short-circuits only when `alert_phase=done` — `frozen` is a resumable suspended state and re-arms on the next finding with severity >= warning (resetting `alert_phase=pending` and `alert_retry_count=0`). When alert is pending and session-close reaches SC-6 (Final Report), it emits `pre_final_report_gate_complete` and yields so the Stop hook can fire alert first.

**Alert three-phase output protocol (#929):**

1. **Draft** — Append each finding with `--finding-status draft` (keeps `alert_phase=pending`).
2. **Adversarial review** — Run `bin/supervisor-review-codex` (Codex per-item AGREE/DISAGREE).
3. **Adjudicate and finalize** — Single call: `supervisor-write-alert --confirm-finding-ids <csv> --drop-finding-ids <csv> --set-alert-phase done`. `cumulative_severity` is computed from confirmed findings only.

Helper modules: `hooks/lib/supervisor-finding-status.js` and `hooks/lib/codex-review-parse.js`.

**Trigger collector:** `hooks/lib/supervisor-guard/collect-audit-triggers.js` — pure function for audit mode trigger detection (stage-boundary + severity-threshold). Uses `AUDIT_SEVERITY_THRESHOLD` constant.

**"escalation" terminology abolished:** The three concepts previously unified as "escalation" are now distinct: (1) **severity-threshold** — `AUDIT_SEVERITY_THRESHOLD` level check (`cumulative_severity === "error"`); (2) **recurrence-patterns** — same failure mode across multiple alert reviews (detected by audit mode); (3) **arming** — `ensureAlertScheduled` / `audit_armed_at` set.

**Schema validation failures:** logged to `console.error` only — when the state file cannot be written, no finding is recorded for that case (known observation hole).

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
