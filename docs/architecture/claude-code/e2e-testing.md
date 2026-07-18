# E2E Test Coverage — Claude Code Hooks

Current L3 coverage status for hooks that require a live `claude -p` session.
L2 tests cannot exercise real Stop-event, SubagentStop, or PostCompact paths.

## Hook Coverage Map

| Hook | E2E Test | Coverage type | L3 gap summary |
|---|---|---|---|
| `hooks/workflow-mark.js` | `tests/feature-943-e2e-workflow-mark.sh` | RUN_E2E-gated (real `claude -p`) | Most sentinel dispatch paths covered by L1 unit tests; this validates hook registration. |
| `hooks/stop-confirm-plan-guard.js` | `tests/feature-943-e2e-stop-confirm-plan-guard.sh` | deterministic direct-node (11 cases) | Layer 1 + Layer 2 classifier boundaries fully covered; live Stop-event not exercised. |
| `hooks/stop-final-report-guard.js` | `tests/feature-943-e2e-stop-final-report-guard.sh` | deterministic direct-node (8 cases) | Paired with existing L2 `feature-534-stop-final-report-guard.sh`; real Stop-event path not exercised. |
| `hooks/session-start.js` | `tests/feature-943-e2e-session-start.sh` | direct-node E2/E3 + RUN_E2E-gated E1 | additionalContext and CONV_LANG covered by direct-node; state inheritance and zombie cleanup are L3 gaps. |
| `hooks/subagent-start.js` | `tests/feature-943-e2e-subagent-start.sh` | deterministic direct-node (6 cases) | Paired with existing L2 `feature-1303-lang-hooks/group2-subagent-start.sh`; real Task-tool dispatch not exercised. |
| `hooks/lang-inject.js` | `tests/feature-943-e2e-lang-inject.sh` | deterministic direct-node (4 cases) | Paired with existing L2 `feature-1303-lang-hooks/group1-lang-inject.sh`; real UserPromptSubmit not exercised. |
| `hooks/post-compact.js` | `tests/feature-943-e2e-post-compact.sh` | deterministic direct-node (4 cases) | Settings registration, re-injection, workflow steps, CONV_LANG covered; real PostCompact event not exercised. |
| `hooks/stop-enforce-worktree-on-warn.js` | `tests/feature-943-e2e-stop-enforce-worktree-on-warn.sh` | deterministic direct-node (3 cases) | OFF-only and balanced OFF+ON covered; ON-then-OFF order is an untested advisory path. |
| `hooks/supervisor-guard.js` | none | OUT — deferred | No observable signal under `claude -p --output-format json`; re-evaluate after #937 phase 2. |

## Two E2E Test Types

**Issue-specific tests** (`tests/feature-943-e2e-*.sh`): hook-level coverage for the 8 L3-gap hooks added in #943. Most are deterministic direct-node (always run); two files have one `RUN_E2E`-gated case each (`workflow-mark.sh`, `session-start.sh`).

**Matrix coverage run**: run all `RUN_E2E`-gated tests in one pass. Use `bin/run-e2e-matrix.sh` to discover and execute every `tests/*.sh` file that contains a `RUN_E2E`-gated case.
