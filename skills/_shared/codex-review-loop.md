# Codex Review Loop — Shared Protocol

Used by `make-outline-plan` MOP-5, `make-detail-plan` MDP-5, `review-plan-security` RPS-2, and `review-tests` RT-3. The mechanical
parts (context build → codex invocation → verdict parse) are enforced by the
`bin/run-codex-review-loop` wrapper.

`EXTENSIONS_USED` is owned by the caller.

## Parameters (caller supplies)

| Parameter | outline value | detail value |
|---|---|---|
| FORMAT | `outline-plan` | `detail-plan` |
| RAW_FILE | `<PLANS_DIR>/<session-id>-outline-codex-round-<N>-raw.md` | `<PLANS_DIR>/<session-id>-codex-round-<N>-raw.md` |
| CONCERNS_LOG | `<PLANS_DIR>/<session-id>-outline-concerns-log.md` | `<PLANS_DIR>/<session-id>-concerns-log.md` |
| DEBUG_LOG | `<PLANS_DIR>/<session-id>-outline-debug.log` | `<PLANS_DIR>/<session-id>-detail-debug.log` |
| CAP | 1 | 2 |
| MAX_EXTENSIONS | 1 | 1 |
| PLANNER_AGENT | `outline-planner` | `detail-planner` |
| REVIEWER_AGENT | `outline-reviewer` | `detail-reviewer` |
| ACCEPTED_TRADEOFFS_FILE | `<PLANS_DIR>/<session-id>-intent.md` | `<PLANS_DIR>/<session-id>-outline.md` |
| NON_APPROVED_VERDICT | `MISSING_ALTERNATIVE:` | `NEEDS_REVISION` |

## Parameters (review-only formats)

| Parameter | security-plan | test-review |
|---|---|---|
| FORMAT | `security-plan` | `test-review` |
| RAW_FILE | `<PLANS_DIR>/<session-id>-security-plan-codex-round-<N>-raw.md` | `<PLANS_DIR>/<session-id>-test-review-codex-round-<N>-raw.md` |
| CONCERNS_LOG | `<PLANS_DIR>/<session-id>-security-plan-concerns-log.md` | `<PLANS_DIR>/<session-id>-test-review-concerns-log.md` |
| DEBUG_LOG | `<PLANS_DIR>/<session-id>-security-plan-debug.log` | `<PLANS_DIR>/<session-id>-test-review-debug.log` |
| CAP | 1 | 1 |
| MAX_EXTENSIONS | 0 | 0 |
| PLANNER_AGENT | (none — review-only) | (none — review-only) |
| REVIEWER_AGENT | `plan-security-reviewer` | `test-reviewer` |
| ACCEPTED_TRADEOFFS_FILE | `<PLANS_DIR>/<session-id>-outline.md` | `<PLANS_DIR>/<session-id>-outline.md` |
| NON_APPROVED_VERDICT | `NEEDS_REVISION` | `NEEDS_REVISION` |

## Single-round review-only formats

`security-plan` and `test-review` have no PLANNER_AGENT.
CAP=1 / MAX_EXTENSIONS=0 — single round only; no extension budget.
A NON_APPROVED_VERDICT (exit 1) is TERMINAL — the caller presents concerns and stops; no re-delegation to a planner.
`review-tests` fires `WORKFLOW_REVIEW_TESTS_WARNINGS` on exit 1; `review-plan-security` presents concerns and proposes mitigations.
Exit 0 = APPROVED (review-tests fires `WORKFLOW_REVIEW_TESTS_COMPLETE`).
Exit 3 = codex CLI unusable → caller silently launches CC REVIEWER_AGENT fallback.
Exit 4 = HALT — same as Contract B; no fallback.

## Round Counter (ROUND_NUMBER)

`ROUND_NUMBER` is an orchestrator-tracked integer independent of `EXTENSIONS_USED`.

- Outline stage (CAP=1 / MAX_EXTENSIONS=1): ROUND_NUMBER is 1 on the initial review and 2 after a cap-menu `extend` / `AUTO_EXTEND`.
- Detail stage (CAP=2 / MAX_EXTENSIONS=1): ROUND_NUMBER reaches 2 on the second review within the same `EXTENSIONS_USED=0` budget; if the user extends, ROUND_NUMBER reaches 3 while `EXTENSIONS_USED=1`.

ROUND_NUMBER is NEVER `EXTENSIONS_USED + 1` — that derivation would mis-tag the second review of the detail stage as "round 1" and break the ESCALATE policy.

`bin/run-codex-review-loop` owns the counter at `<PLANS_DIR>/<session-id>-<format>-round-number.txt`; stage wrappers do not touch it. `--round` is optional (auto-incremented from ROUND_FILE when omitted). The file is deleted on terminal verdicts (exit 0/2/6 for all formats; exit 1 for single-round formats) and `<PLANS_DIR>/<session-id>-<format>-last-round.txt` is written with the final round value. It persists on CONTINUE (exit 1 for multi-round formats) and AUTO_EXTEND (exit 5). On infrastructure failure (exit 3/4/7) the counter is rolled back to its pre-call value.

`--force-round <N>` overrides the recorded counter for recovery and test use only — it announces itself on stderr and bypasses the sequence check. No shipped skill caller uses it; the flag is reserved for manual recovery from a corrupt counter and for test harnesses that need to start at an arbitrary round.

## Concern-ID Ledger

`bin/run-codex-review-loop` maintains a per-session ledger at `<PLANS_DIR>/<session-id>-<format>-concern-ledger.txt`. The wrapper accepts a REQUIRED `--round N` argument (no default); the per-stage wrapper script always supplies it.

Schema, lifecycle states, binding tiers, and the category vocabulary: `skills/_shared/concern-ledger.md` (SSOT). Full concern text is stored verbatim (no truncation).

- Round 1: assigns C1, C2, … to each concern; rewrites the forwarded reviewer output so concerns appear as `C<N>. [<SEV>] …`; writes ledger at the end of Round 1 processing.
- Round 2+: validates each `C<N>:` reference against the ledger; drops unknown IDs from forwarded output and emits a stderr warning `run-codex-review-loop: discarded new concern IDs in round N: C5, C6`; tallies residual severity from ledger for unresolved concerns.
- Missing ledger at Round 2: exits 4 with `ledger missing for round N` diagnostic (no silent recreation).

The Round 2+ codex prompt in `bin/review-plan-codex` is switched to Cn-reference form via `--round 2 --ledger <path>`. Applies to both `--format detail-plan` and `--format outline-plan`.

The ledger is deleted on APPROVED (exit 0) and ESCALATE (exit 2), and persists across CONTINUE (exit 1). HIGH_UNRESOLVED (exit 6) does not delete the ledger — it is finalized with mode=terminal and remains on disk.

Before the ledger is dropped on an ending that never converged (ESCALATE, or CONTINUE at the cap), the wrapper finalizes it into `<PLANS_DIR>/<session-id>-<format>-unresolved-concerns.json`. That write is fail-CLOSED: when it does not succeed the wrapper returns exit 7 instead of the would-be verdict, so no caller emits its completion sentinel over concerns nobody can read.

Within the wrapper, `bin/review-loop-verdict <round> <high> <medium> <low> [--budget-remaining N] [--risk-signal <value>]` is invoked on every non-APPROVED reviewer verdict. Its decision overrides the raw reviewer verdict for exit-code selection (internal contract): APPROVED→0, CONTINUE→1, ESCALATE→2, HIGH_UNRESOLVED→6, arg error→4, AUTO_EXTEND→5. The wrapper then converts internal exit codes to public exit codes before returning to the caller (see Contract B below).

## Per-round protocol

While a round is in flight, the caller MAY read the already-frozen upstream plan artifacts (intent / outline) to pre-check scope coverage — never the round's own output files (SC-W — `skills/_shared/subagent-concurrency.md`).

### a. Write planner output to final artifact

The planner writes its output to `<PLANS_DIR>/<session-id>-{outline,detail}.md` via the Write tool. `assemble-mandatory.sh` later overwrites this same file in place to inject the mandatory sections.

### b/c/d. Invoke wrapper (single Bash call)

Each caller skill invokes its own per-skill extraction script (Bash tool):
- `skills/make-detail-plan/scripts/run-codex-review-loop.sh` (detail stage)
- `skills/make-outline-plan/scripts/run-codex-review-loop.sh` (outline stage)
- `skills/review-plan-security/scripts/run-codex-review-loop.sh` (security-plan stage)
- `skills/review-tests/scripts/run-codex-review-loop.sh` (test-review stage)

Each script reads from the environment:
- Required: `AGENTS_CONFIG_DIR`, `SESSION_ID`, `PLANS_DIR`, `EXTENSIONS_USED`
- Optional: `CTX_SURVEY_CODE`, `CTX_SURVEY_HISTORY`, `CTX_CONCERNS_LOG` — each passed as `--context` when the file exists and is non-empty.

Exit codes pass through to the caller unchanged.

The wrapper internally:
1. Builds (per-stage, marker-gated at `<PLANS_DIR>/<session-id>-codex-context.<FORMAT>.built`)
   the unified context at `<PLANS_DIR>/<session-id>-codex-context.md` (renamed from
   `-context.md` to avoid WI-9 collision) via
   `bin/build-codex-context`. Section headers: `## Section 1: Intent (User Requirements)`
   and `## Section 2: Outline (Design Proposal)`, prefixed by
   `<!-- Source: <PLANS_DIR>/<session-id>-intent.md -->` and
   `<!-- Source: <PLANS_DIR>/<session-id>-outline.md -->`.
   - If only the intent file exists, only Section 1 is written.
   - If only the outline file exists, only Section 2 is written.
   - If neither exists, the output file is deleted and no `--context <context.md>` is passed downstream.
2. Pre-flights `AGENTS_CONFIG_DIR` AND `$AGENTS_CONFIG_DIR/rules/core-principles.md`
   (both mandatory — missing either → exit 4).
3. Calls `review-plan-codex` with the assembled flags, always passing
   `--context "$AGENTS_CONFIG_DIR/rules/core-principles.md"` plus the unified
   context.md (when non-empty) plus each caller-supplied `--context` whose target
   exists and is non-empty.
4. Parses status header + verdict.

The hard-cap gate fires **after** the reviewer's verdict is recorded (post-verdict),
not before the reviewer runs. The reviewer always gets at least one look per
planner-cap budget: `limit = 1 + cap + extensions_used`. On exit 1
(NON_APPROVED_VERDICT) the wrapper re-checks the cap and promotes to exit 2
(`FAILED — round cap reached`) when the budget is exhausted.

## Exit code → orchestrator action (SSOT) {#exit-code--orchestrator-action-ssot}

Quick reference (public exit codes — Contract B):

| Exit | Name | Orchestrator action |
|---|---|---|
| 0 | APPROVED | Write/confirm phase. |
| 1 | CONTINUE | Capture RAW → append round log → re-invoke planner. |
| 2 | ESCALATE | Present concern summary → stop loop. |
| 3 | codex CLI unusable | Silently launch `REVIEWER_AGENT` fallback. |
| 4 | HALT | Surface stderr verbatim; do not fall back. |
| 5 | AUTO_EXTEND | `EXTENSIONS_USED += 1` → re-enter loop. |
| 6 | HIGH_UNRESOLVED | Present HIGH concern summary → stop loop; do not proceed to write/confirm. |
| 7 | FINALIZE_FAILED | HALT; surface `## Concern Ledger: FINALIZE-FAILED` line; do not emit sentinel. |
| 8 | review-tests re-invoked after terminal | HALT; no staged-tests change detected since last terminal exit. |

Full tables (Contract A, Contract B), RAW persistence rules, RAW naming, per-round log protocol, Outcomes, and Rationale: [`skills/_shared/codex-review-loop/exit-codes.md`](codex-review-loop/exit-codes.md).
