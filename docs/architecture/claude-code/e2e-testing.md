# E2E Test Coverage — Claude Code Hooks

Current L3 coverage status for hooks that require a live `claude -p` session.
L2 tests cannot exercise real Stop-event, SubagentStop, or PostCompact paths.

## Hook Coverage Map

| Hook | Current L2 | Priority | Rationale |
|---|---|---|---|
| `hooks/workflow-mark.js` | partial (`tests/feature-robust-workflow/settings-e2e.sh` — RUN_E2E-gated, extracted in PR #964) | **P1 — extract** | E2E exists but gated by RUN_E2E in a dedicated file; #943 to make it the default coverage path. |
| `hooks/stop-confirm-plan-guard.js` | none | **P1 — add** | Stop-hook sentinel-order validation is unreachable from unit tests; the hook reads the live transcript. |
| `hooks/stop-final-report-guard.js` | extensive (`tests/feature-534-stop-final-report-guard.sh`, 20+ L2 cases) | **P2 — add E2E** | L2 is thorough but cannot exercise the real Stop-event path; one E2E case validates registration. |
| `hooks/session-start.js` | partial (`tests/feature-772-session-start-cleanup-inherit.sh` covers env-file write) | **P2 — add E2E** | env-file write covered at L2; need E2E for actual CONV_LANG injection into a live session. |
| `hooks/subagent-start.js` | none | **P3 — add** | Sub-agent context injection requires a real Task tool call — only reachable via `claude -p`. |
| `hooks/post-compact.js` | none | **P3 — add** | PostCompact event is not reproducible at L2 (requires real compaction trigger). |
| `hooks/stop-askuserquestion-required.js` | L2 in `tests/feature-stop-guard-layer2.sh` | **P2 — add E2E** | Stop hook requiring AskUserQuestion pre-fire is only observable in a live session. |
| `hooks/stop-enforce-worktree-on-warn.js` | none (advisory) | **P3 — add** | Advisory context-injection is only confirmable in a live session. |
| `hooks/supervisor-guard.js` | L2-only (`tests/feature-719-supervisor-guard-hook.sh`, `tests/feature-883-supervisor-guard-wsid.sh`) | **OUT — defer** | No observable signal under `claude -p --output-format json`; re-evaluate after #937 phase 2. |

## Implementation Order (#943)

1. `workflow-mark.js` — extract existing embedded E2E to a dedicated file.
2. `stop-confirm-plan-guard.js` — write fresh E2E.
3. `stop-final-report-guard.js` — write fresh E2E (paired with existing L2; both kept).
4. `stop-askuserquestion-required.js` — write fresh E2E.
5. `session-start.js` — write fresh E2E (paired with `feature-772-session-start-cleanup-inherit.sh`).
6. `subagent-start.js` — write fresh E2E.
7. `post-compact.js` — write fresh E2E.
8. `stop-enforce-worktree-on-warn.js` — write fresh E2E.
