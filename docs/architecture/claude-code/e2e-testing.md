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
| `hooks/stop-exit-worktree-warn.js` | TL2 (`tests/feature-1610-stop-exit-worktree-warn.sh`) | **P3 — add TL3** | Advisory ExitWorktree reminder; union of state + transcript evidence is only confirmable end-to-end in a live session (#1610). |
| `hooks/postuse-native-worktree-record.js` | TL2 (`tests/feature-1610-stop-exit-worktree-warn.sh` Section R) | **P3 — add TL3** | State stamping is TL2-testable by payload injection, but the real EnterWorktree/ExitWorktree → PostToolUse → state-write path needs a live session (#1610). |
| `hooks/supervisor-guard.js` | TL2-only (`tests/feature-719-supervisor-guard-hook.sh`, `tests/feature-883-supervisor-guard-wsid.sh`) | **OUT — defer** | No observable signal under `claude -p --output-format json`; re-evaluate after #937 phase 2. |
| `hooks/preuse-auto-approve.js` | TL2 (`tests/feature-preuse-auto-approve.sh` — 24 cases: Monitor allow, EnterWorktree boundary matrix, AUTO_APPROVE_TOOLS toggle, symlink resolution) | **TL3 gap** | hook-registration gap: real PreToolUse firing and `permissionDecision` honor by the CC runtime unverifiable at TL2 (#1849). |
| `hooks/instructions-loaded-audit.js` | TL2 (`tests/cc-instructions-loaded-audit.sh`, `tests/cc-instructions-loaded-quiescence.sh`, `tests/cc-instructions-loaded-registration.sh`) + TL3 gate (`tests/TL3-rules-injection-off-switch.sh` — RUN_TL3-gated) | **TL3 gated** | TL2 pins verdicts and the receipt/quiescence protocol by payload injection; only a real session proves the host fires `InstructionsLoaded` at all and that the reserved never-match glob really suppresses injection (#1652). |
| `hooks/block-comment-block-size.js` | TL2 (`tests/feature-1894-hook-comment-block.sh` — registration, matcher, decision-boundary, and no-bypass cases) | **TL3 gap** | hook-registration gap: real PreToolUse firing and `permissionDecision: "deny"` honor by the CC runtime — actually rejecting an Edit that grows a comment block past the threshold — is unverifiable at TL2 (#1894). |
| `hooks/record-off-skill-invocation.js` | **TL3 covered for the `claude -p` shape** (`tests/TL3-hook-record-off-skill-invocation.sh` — RUN_TL3-gated, also exercises the same-turn consumer seam `enforce-override-handlers/off-clearance.js`; TL2: `tests/enforce-off-emergency-provenance.sh`) | **TL3 gap** (#2157) | TL2 feeds synthetic stdin, so the premise of the whole provenance claim — that the runtime fires UserPromptSubmit for a typed `/enforce-workflow-off` and hands the hook that text, and that the same-turn consumer stamps `provenance: user_skill_invocation` off the resulting marker — is only observable live, through a stdin-capturing wrapper in front of the real hook (#1780 M-2 regex defect, fixed in `7c40bf48`). `claude -p` delivers the prompt unexpanded, so this row's TL3 coverage never exercises the interactive client's `<command-name>` wrapper — that expansion shape is pinned at TL2 (P1) only, same open gap as the other `TL3 gap` rows above. |
| `hooks/confirm-forge-target-ownership.js` | TL2 (`tests/feature-2053-forge-target-ownership.sh`) + TL3 (`tests/TL3-hook-forge-target-ownership.sh` — RUN_TL3-gated) | **TL3 gated** | TL2 pins the detection, resolution and proof matrix by payload injection with a stubbed `gh`; only a live session proves the CC runtime honors `permissionDecision: "ask"` for a real `gh issue create` (#2053). |
| `/resume-session --from` transcript-tail dispatch | TL2 (`tests/feat-2218-resume-from-degradation.sh` — deterministic jsonl location, tail cap, `transcript_tail` carries a path only) | **TL3 gap** → TL4 (#1543) | TL2 pins the CLI half: it writes a capped scratch file and returns its path, never raw text. The other half — the skill launching a summarizer subagent per `skills/resume-session/scripts/summarize-transcript-tail.md` and merging its report back into the resuming conversation — is a model-driven dispatch with no deterministic side-effect file, so it is unobservable below TL4 (#2218). |

## Implementation Order (#943)

1. `workflow-mark.js` — extract existing embedded seam test to a dedicated TL3 file.
2. `stop-confirm-plan-guard.js` — write fresh TL3 seam test.
3. `stop-final-report-guard.js` — write fresh TL3 seam test (paired with existing TL2; both kept).
4. `session-start.js` — write fresh TL3 seam test (paired with `feature-772-session-start-cleanup-inherit.sh`).
5. `subagent-start.js` — TL3 gap documented; real coverage deferred to TL4 (#1543).
6. `post-compact.js` — TL3 gap documented; real coverage deferred to TL4 (#1543).
7. `stop-enforce-worktree-on-warn.js` — future TL3 seam test.
8. `stop-exit-worktree-warn.js` — future TL3 seam test (paired with the advisory sibling above; #1610).
