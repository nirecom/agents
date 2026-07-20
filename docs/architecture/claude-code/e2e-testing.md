# Per-Hook TL3 Test Coverage — Claude Code Hooks

Current TL3 coverage status for hooks that require a live `claude -p` session
(single-component seam tests; see `rules/test.md` for the TL1–TL4 taxonomy — "E2E"
is reserved for TL4 full-pipeline tests). TL2 tests cannot exercise real
Stop-event, SubagentStop, or PostCompact paths.

## Hook Coverage Map

| Hook | Coverage | Priority | Rationale |
|---|---|---|---|
| `hooks/workflow-mark.js` | **TL3 covered** (`tests/TL3-hook-workflow-mark.sh` — RUN_TL3-gated) | done (#943) | Live `claude -p` emits a MARK_STEP sentinel via Bash → state file `steps.research.status=complete`. |
| `hooks/stop-confirm-plan-guard.js` | **TL3 covered** (`tests/TL3-hook-stop-confirm-plan-guard.sh` — RUN_TL3-gated) | done (#943) | Turn marker fixture consumed (deleted) by the live Stop hook via readAndDeleteTurnMarkers(). |
| `hooks/stop-final-report-guard.js` | **TL3 covered** (`tests/TL3-hook-stop-final-report-guard.sh`; TL2: `tests/feature-534-stop-final-report-guard.sh`, 20+ cases) | done (#943) | Live Stop with env-file fixture but no Final Report heading → decision:block → non-zero exit (block case). |
| `hooks/session-start.js` | **TL3 covered** (`tests/TL3-hook-session-start.sh`; TL2: `tests/feature-772-session-start-cleanup-inherit.sh`) | done (#943) | Fresh live session → createInitialState writes all-pending state; additionalContext surfaces the sid. |
| `hooks/subagent-start.js` | **TL3 gap** (partial TL2: `tests/feature-1303-lang-hooks/group2-subagent-start.sh`; gap documented in `tests/TL3-hook-subagent-start.sh`) | TL3 gap (#943) → TL4 (#1543) | No observable side-effect file; sub-agent output-language signal is non-deterministic — no automated TL3. |
| `hooks/lang-inject.js` | TL2 (`tests/feature-1303-lang-hooks/group1-lang-inject.sh` — real spawn: CONV_LANG per-turn, PLAN_LANG when planning, fail-open) | **P3 — add TL3** | hook-registration gap: real UserPromptSubmit firing and `additionalContext` surfacing into a live session are unverifiable at TL2. |
| `hooks/post-compact.js` | **TL3 gap** (documented in `tests/TL3-hook-post-compact.sh`) | TL3 gap (#943) → TL4 (#1543) | PostCompact fires only on real compaction, unreachable in a short `claude -p` session; no deterministic side-effect. |
| `hooks/stop-enforce-worktree-on-warn.js` | none (advisory) | **P3 — add TL3** | Advisory context-injection is only confirmable in a live session. |
| `hooks/supervisor-guard.js` | TL2-only (`tests/feature-719-supervisor-guard-hook.sh`, `tests/feature-883-supervisor-guard-wsid.sh`) | **OUT — defer** | No observable signal under `claude -p --output-format json`; re-evaluate after #937 phase 2. |

## Implementation Order (#943)

1. `workflow-mark.js` — extract existing embedded seam test to a dedicated TL3 file.
2. `stop-confirm-plan-guard.js` — write fresh TL3 seam test.
3. `stop-final-report-guard.js` — write fresh TL3 seam test (paired with existing TL2; both kept).
4. `session-start.js` — write fresh TL3 seam test (paired with `feature-772-session-start-cleanup-inherit.sh`).
5. `subagent-start.js` — TL3 gap documented; real coverage deferred to TL4 (#1543).
6. `post-compact.js` — TL3 gap documented; real coverage deferred to TL4 (#1543).
7. `stop-enforce-worktree-on-warn.js` — future TL3 seam test.
