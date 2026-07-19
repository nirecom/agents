# E2E Test Coverage — Claude Code Hooks

Current L3 coverage status for hooks that require a live `claude -p` session.
L2 tests cannot exercise real Stop-event, SubagentStop, or PostCompact paths.

## Hook Coverage Map

| Hook | Current L2 | Priority | Rationale |
|---|---|---|---|
| `hooks/workflow-mark.js` | **L3 covered** (`tests/feature-943-e2e-workflow-mark.sh` — RUN_E2E-gated) | done (#943) | Live `claude -p` emits a MARK_STEP sentinel via Bash → state file `steps.research.status=complete`. |
| `hooks/stop-confirm-plan-guard.js` | **L3 covered** (`tests/feature-943-e2e-stop-confirm-plan-guard.sh` — RUN_E2E-gated) | done (#943) | Turn marker fixture consumed (deleted) by the live Stop hook via readAndDeleteTurnMarkers(). |
| `hooks/stop-final-report-guard.js` | **L3 covered** (`tests/feature-943-e2e-stop-final-report-guard.sh`; L2: `tests/feature-534-stop-final-report-guard.sh`, 20+ cases) | done (#943) | Live Stop with env-file fixture but no Final Report heading → decision:block → non-zero exit (block case). |
| `hooks/session-start.js` | **L3 covered** (`tests/feature-943-e2e-session-start.sh`; L2: `tests/feature-772-session-start-cleanup-inherit.sh`) | done (#943) | Fresh live session → createInitialState writes all-pending state; additionalContext surfaces the sid. |
| `hooks/subagent-start.js` | **L3 gap** (partial L2: `tests/feature-1303-lang-hooks/group2-subagent-start.sh`; gap documented in `tests/feature-943-e2e-subagent-start.sh`) | L3 gap (#943) | No observable side-effect file; sub-agent output-language signal is non-deterministic — no automated L3. |
| `hooks/lang-inject.js` | L2 (`tests/feature-1303-lang-hooks/group1-lang-inject.sh` — real spawn: CONV_LANG per-turn, PLAN_LANG when planning, fail-open) | **P3 — add E2E** | hook-registration gap: real UserPromptSubmit firing and `additionalContext` surfacing into a live session are unverifiable at L2. |
| `hooks/post-compact.js` | **L3 gap** (documented in `tests/feature-943-e2e-post-compact.sh`) | L3 gap (#943) | PostCompact fires only on real compaction, unreachable in a short `claude -p` session; no deterministic side-effect. |
| `hooks/stop-enforce-worktree-on-warn.js` | none (advisory) | **P3 — add** | Advisory context-injection is only confirmable in a live session. |
| `hooks/supervisor-guard.js` | L2-only (`tests/feature-719-supervisor-guard-hook.sh`, `tests/feature-883-supervisor-guard-wsid.sh`) | **OUT — defer** | No observable signal under `claude -p --output-format json`; re-evaluate after #937 phase 2. |

## Implementation Order (#943)

1. `workflow-mark.js` — extract existing embedded E2E to a dedicated file.
2. `stop-confirm-plan-guard.js` — write fresh E2E.
3. `stop-final-report-guard.js` — write fresh E2E (paired with existing L2; both kept).
4. `session-start.js` — write fresh E2E (paired with `feature-772-session-start-cleanup-inherit.sh`).
5. `subagent-start.js` — write fresh E2E.
6. `post-compact.js` — write fresh E2E.
7. `stop-enforce-worktree-on-warn.js` — write fresh E2E.
