# Exit code → orchestrator action (SSOT) {#exit-code--orchestrator-action-ssot}

Two contracts govern exit codes. The internal contract (between `review-loop-verdict` and `run-codex-review-loop`) is never visible to SKILL callers; the public contract (between `run-codex-review-loop` and the SKILL orchestrator) is the authoritative interface.

**Contract A — Internal verdict exit code** (`review-loop-verdict` → `run-codex-review-loop`, internal only):

| Internal exit | Verdict | `run-codex-review-loop` action |
|---|---|---|
| 0 | APPROVED | Delete ledger → public exit 0 |
| 1 | CONTINUE | hard-cap-gate recheck → public exit 1 (or escalated 2) |
| 2 | ESCALATE | Copy ledger to cap-snapshot + delete → public exit 2 |
| 4 | Arg error | public exit 4 |
| 5 | AUTO_EXTEND | Keep ledger → **public exit 5** |
| 6 | HIGH_UNRESOLVED | Finalize ledger (mode=terminal, not deleted) → public exit 6 |

**Contract B — Public wrapper exit code** (`run-codex-review-loop` → SKILL caller):

| Public exit | Meaning | Orchestrator action |
|---|---|---|
| 0 | APPROVED | Return to caller for the write/confirm phase. |
| 1 | NON_APPROVED_VERDICT (CONTINUE) | Capture stdout to `RAW_FILE` (step d.1) → append round log + planner trailer to `CONCERNS_LOG` (step e) → re-invoke `PLANNER_AGENT`. |
| 2 | ESCALATE (risk signal + ceiling) | Present concern summary → stop loop. Invoke `review-loop-summarize-concerns --budget-remaining 0` per MOP-6 / MDP-6. |
| 3 | **codex CLI unusable** (SKIPPED / FAILED-other / verdict malformed) | Append `<ISO-timestamp> round=<N> codex unavailable: <stderr>` to `DEBUG_LOG`; **silently launch `REVIEWER_AGENT` subagent**. Do NOT emit to chat. |
| 4 | **Wrapper / config / parser failure** (unset `AGENTS_CONFIG_DIR`, missing `core-principles.md`, missing arg, missing option value, missing binary, unrecognized status header, etc.) | **HALT with blocking error.** Surface the wrapper's stderr verbatim to the user. Do **NOT** fall back to `REVIEWER_AGENT` — exit 4 means the enforcement infrastructure itself is broken, and silent fallback would hide that. Append diagnostic to `DEBUG_LOG` then abort the skill. Sub-case: when round >= 2 is requested but the ledger file is absent, exit 4 is returned regardless of whether `--ledger` was supplied explicitly. |
| 5 | AUTO_EXTEND | `EXTENSIONS_USED += 1` → re-enter review loop (no user dialog). |
| 6 | **HIGH_UNRESOLVED** — budget ceiling with unresolved HIGH concerns and no risk signal | Present unresolved HIGH concern summary → stop loop; do not proceed to the write/confirm phase. Invoke `review-loop-summarize-concerns --budget-remaining 0` with the live ledger (not a cap-snapshot — the ledger is finalized but not deleted). |
| 7 | **FINALIZE_FAILED** — the unresolved-concerns artifact could not be written | **HALT.** Surface the `## Concern Ledger: FINALIZE-FAILED` line (it names the recovered ledger copy) and the would-be verdict it replaced. Do NOT emit the step's completion sentinel and do NOT fall back to `REVIEWER_AGENT`. Re-run after fixing the cause; the ledger is intact. |
| 8 | **review-tests wrapper only** — re-invoked after a terminal exit with tests unchanged | **HALT.** The terminal guard in `skills/review-tests/scripts/run-codex-review-loop.sh` detected no change in the staged-tests fingerprint since the last terminal exit. |

**Note: exit 6 means HIGH_UNRESOLVED in both contracts** — internal exit 6 (from `review-loop-verdict`) maps directly to public exit 6; the meaning is the same in both directions.

**Critical distinction (public exits 3 vs 4):** exit 3 and exit 4 look superficially similar (neither produced a usable verdict) but require opposite responses. Exit 3 is "codex was given a fair chance and could not perform" → graceful degradation to the local reviewer is correct. Exit 4 is "the wrapper / config / parser is broken" → the local reviewer fallback would let the broken pipeline keep running silently. Fix the underlying problem (set the env var, install the missing binary, restore `core-principles.md`, etc.) and re-run.

SKILL.md callers MUST NOT reproduce this table — they reference it by link.

### d.1. Raw-codex persistence (on exit 1, 2, and 6)

Extract content between `<!-- begin-codex-output -->` and `<!-- end-codex-output -->` from the captured wrapper stdout and write to `RAW_FILE`. RAW is persisted for exit 1 (CONTINUE), exit 2 (ESCALATE), and exit 6 (HIGH_UNRESOLVED). If a RAW_FILE with the same name already exists it is NOT overwritten — `<N>` uniqueness ensures collision is a contract violation.

`<N>` source:
- Terminal exits (0, 2, 6 for all formats; 1 for single-round formats `security-plan`/`test-review`): read `<PLANS_DIR>/<session-id>-<format>-last-round.txt` (written by the wrapper's `_srn_terminate` path).
- Continuing exits (1 for multi-round formats `detail-plan`/`outline-plan`): read `<PLANS_DIR>/<session-id>-<format>-round-number.txt`.
- No arithmetic (`- 1`) is needed — both files hold the actual round number directly.

**RAW_FILE naming by format** (all paths relative to `<PLANS_DIR>/`):

| format | RAW_FILE pattern |
|---|---|
| detail-plan | `<session-id>-codex-round-<N>-raw.md` |
| outline-plan | `<session-id>-outline-codex-round-<N>-raw.md` |
| security-plan | `<session-id>-security-plan-codex-round-<N>-raw.md` |
| test-review | `<session-id>-test-review-codex-round-<N>-raw.md` |

### e. Symmetric round log + planner-response trailer

Append to `CONCERNS_LOG`: a `## Round <N> (<ISO-timestamp>)` header, `Verdict: <NON_APPROVED_VERDICT>`, a `Concerns (verbatim from codex):` block with numbered concern lines, and `Planner's intended response (next round):` followed by the verbatim `ROUND_RESPONSE` trailer from `PLANNER_AGENT`.

## Outcomes

- Public exit 0 → return to caller for the write/confirm phase (APPROVED).
- Public exit 1 → caller increments revision-round counter; re-invokes `PLANNER_AGENT`.
- Public exit 2 → caller presents concern summary and stops the loop (ESCALATE path).
- Public exit 3 → caller silently falls back to `REVIEWER_AGENT` subagent.
- **Public exit 4 → caller HALTS with blocking error; no fallback.**
- **Public exit 5 → caller increments `EXTENSIONS_USED` and re-enters review loop (AUTO_EXTEND path).**
- **Public exit 6 → caller presents unresolved HIGH concern summary and stops the loop (HIGH_UNRESOLVED path); does not proceed to write/confirm phase.**
- **Public exit 7 → caller HALTS, withholds the completion sentinel, and reports the FINALIZE-FAILED line.**

## Rationale: why a wrapper and not prose

The previous version of this protocol relied on prose ordering instructions. An orchestrator
that skipped step c (invoking `REVIEWER_AGENT` directly without ever calling `review-plan-codex`)
was not detected. The wrapper makes the codex path the only sanctioned mechanical entry point;
a `REVIEWER_AGENT` invocation is justified ONLY by exit 3, and exit 4 specifically forbids it.
