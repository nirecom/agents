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

The per-stage wrapper script (`skills/make-{detail,outline}-plan/scripts/run-codex-review-loop.sh`) maintains ROUND_NUMBER on disk at `<PLANS_DIR>/<session-id>-<format>-round-number.txt` and increments it on each invocation. The file holds a single decimal integer `\n`-terminated. The wrapper passes `--round "$ROUND_NUMBER"` to `bin/run-codex-review-loop`. The file is deleted on public exit 0 (APPROVED or LAND absorbed) or public exit 2 (ESCALATE); it persists on exit 1 (CONTINUE) and exit 5 (AUTO_EXTEND) — and on exit 4 (FATAL_ERROR, per #776: cleanup-on-exit-4 keeps retry path clean).

## Concern-ID Ledger

`bin/run-codex-review-loop` maintains a per-session ledger at `<PLANS_DIR>/<session-id>-<format>-concern-ledger.txt`. The wrapper accepts a REQUIRED `--round N` argument (no default); the per-stage wrapper script always supplies it.

Each ledger line is pipe-delimited: `C<N>|<SEVERITY>|<full concern text>`. Full text is stored verbatim (no truncation).

- Round 1: assigns C1, C2, … to each concern; rewrites the forwarded reviewer output so concerns appear as `C<N>. [<SEV>] …`; writes ledger at the end of Round 1 processing.
- Round 2+: validates each `C<N>:` reference against the ledger; drops unknown IDs from forwarded output and emits a stderr warning `run-codex-review-loop: discarded new concern IDs in round N: C5, C6`; tallies residual severity from ledger for unresolved concerns.
- Missing ledger at Round 2: exits 4 with `ledger missing for round N` diagnostic (no silent recreation).

The Round 2+ codex prompt in `bin/review-plan-codex` is switched to Cn-reference form via `--round 2 --ledger <path>`. Applies to both `--format detail-plan` and `--format outline-plan`.

The ledger is deleted on terminal verdicts (APPROVED, ESCALATE) and persists across CONTINUE.

Within the wrapper, `bin/review-loop-verdict <round> <high> <medium> <low> [--budget-remaining N] [--risk-signal <value>]` is invoked on every non-APPROVED reviewer verdict. Its decision overrides the raw reviewer verdict for exit-code selection (internal contract): APPROVED→0, CONTINUE→1, ESCALATE→2, LAND→3, arg error→4, AUTO_EXTEND→5. The wrapper then converts internal exit codes to public exit codes before returning to the caller (see Contract B below).

## Per-round protocol

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

Two contracts govern exit codes. The internal contract (between `review-loop-verdict` and `run-codex-review-loop`) is never visible to SKILL callers; the public contract (between `run-codex-review-loop` and the SKILL orchestrator) is the authoritative interface.

**Contract A — Internal verdict exit code** (`review-loop-verdict` → `run-codex-review-loop`, internal only):

| Internal exit | Verdict | `run-codex-review-loop` action |
|---|---|---|
| 0 | APPROVED | Delete ledger → public exit 0 |
| 1 | CONTINUE | hard-cap-gate recheck → public exit 1 (or escalated 2) |
| 2 | ESCALATE | Copy ledger to cap-snapshot + delete → public exit 2 |
| 3 | LAND | Delete ledger → **public exit 0** (silent land = absorbed as approved) |
| 4 | Arg error | public exit 4 |
| 5 | AUTO_EXTEND | Keep ledger → **public exit 5** |

**Contract B — Public wrapper exit code** (`run-codex-review-loop` → SKILL caller):

| Public exit | Meaning | Orchestrator action |
|---|---|---|
| 0 | APPROVED or silent LAND | Return to caller for the write/confirm phase. |
| 1 | NON_APPROVED_VERDICT (CONTINUE) | Capture stdout to `RAW_FILE` (step d.1) → append round log + planner trailer to `CONCERNS_LOG` (step e) → re-invoke `PLANNER_AGENT`. |
| 2 | ESCALATE (risk signal + ceiling) | Present concern summary → stop loop. Invoke `review-loop-summarize-concerns` per MOP-6 / MDP-6. |
| 3 | **codex CLI unusable** (SKIPPED / FAILED-other / verdict malformed) | Append `<ISO-timestamp> round=<N> codex unavailable: <stderr>` to `DEBUG_LOG`; **silently launch `REVIEWER_AGENT` subagent**. Do NOT emit to chat. |
| 4 | **Wrapper / config / parser failure** (unset `AGENTS_CONFIG_DIR`, missing `core-principles.md`, missing arg, missing option value, missing binary, unrecognized status header, etc.) | **HALT with blocking error.** Surface the wrapper's stderr verbatim to the user. Do **NOT** fall back to `REVIEWER_AGENT` — exit 4 means the enforcement infrastructure itself is broken, and silent fallback would hide that. Append diagnostic to `DEBUG_LOG` then abort the skill. Sub-case: when round >= 2 is requested but the ledger file is absent at arg-assembly time, the wrapper auto-downgrades the effective round to 1 and rebuilds the ledger from this round's concerns (concern-ID continuity is lost; tracked by #748). |
| 5 | AUTO_EXTEND | `EXTENSIONS_USED += 1` → re-enter review loop (no user dialog). |

**Note: Internal LAND (exit 3) ≠ Public exit 3** — internal exit 3 is LAND (absorbed to public exit 0); public exit 3 means codex CLI unavailable. These share the same number but belong to different contracts and are never confused because `run-codex-review-loop` converts before returning.

**Critical distinction (public exits 3 vs 4):** exit 3 and exit 4 look superficially similar (neither produced a usable verdict) but require opposite responses. Exit 3 is "codex was given a fair chance and could not perform" → graceful degradation to the local reviewer is correct. Exit 4 is "the wrapper / config / parser is broken" → the local reviewer fallback would let the broken pipeline keep running silently. Fix the underlying problem (set the env var, install the missing binary, restore `core-principles.md`, etc.) and re-run.

SKILL.md callers MUST NOT reproduce this table — they reference it by link.

### d.1. Raw-codex persistence (on exit 1)

Extract content between `<!-- begin-codex-output -->` and `<!-- end-codex-output -->` from
the captured wrapper stdout and write to `RAW_FILE` (`<N>` = prior round-log count + 1).

### e. Symmetric round log + planner-response trailer

Append to `CONCERNS_LOG`:

```
## Round <N> (<ISO-timestamp>)
Verdict: <NON_APPROVED_VERDICT>
Concerns (verbatim from codex):
<numbered concern lines>

Planner's intended response (next round):
<extracted verbatim from PLANNER_AGENT's ROUND_RESPONSE trailer>
```

## Outcomes

- Public exit 0 → return to caller for the write/confirm phase (APPROVED or silent LAND).
- Public exit 1 → caller increments revision-round counter; re-invokes `PLANNER_AGENT`.
- Public exit 2 → caller presents concern summary and stops the loop (ESCALATE path).
- Public exit 3 → caller silently falls back to `REVIEWER_AGENT` subagent.
- **Public exit 4 → caller HALTS with blocking error; no fallback.**
- **Public exit 5 → caller increments `EXTENSIONS_USED` and re-enters review loop (AUTO_EXTEND path).**

## Rationale: why a wrapper and not prose

The previous version of this protocol relied on prose ordering instructions. An orchestrator
that skipped step c (invoking `REVIEWER_AGENT` directly without ever calling `review-plan-codex`)
was not detected. The wrapper makes the codex path the only sanctioned mechanical entry point;
a `REVIEWER_AGENT` invocation is justified ONLY by exit 3, and exit 4 specifically forbids it.
