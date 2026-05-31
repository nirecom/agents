# Codex Review Loop — Shared Protocol

Used by `make-outline-plan` Step 5 and `make-detail-plan` Step 5. The mechanical
parts (context build → codex invocation → verdict parse) are enforced by the
`bin/run-codex-review-loop` wrapper.

`EXTENSIONS_USED` is owned by the caller.

## Parameters (caller supplies)

| Parameter | outline value | detail value |
|---|---|---|
| FORMAT | `outline-plan` | `detail-plan` |
| DRAFT_FILE | `<PLANS_DIR>/drafts/<session-id>-outline-draft.md` | `<PLANS_DIR>/drafts/<session-id>-detail-draft.md` |
| RAW_FILE | `<PLANS_DIR>/drafts/<session-id>-outline-codex-round-<N>-raw.md` | `<PLANS_DIR>/drafts/<session-id>-codex-round-<N>-raw.md` |
| CONCERNS_LOG | `<PLANS_DIR>/drafts/<session-id>-outline-concerns-log.md` | `<PLANS_DIR>/drafts/<session-id>-concerns-log.md` |
| DEBUG_LOG | `<PLANS_DIR>/drafts/<session-id>-outline-debug.log` | `<PLANS_DIR>/drafts/<session-id>-detail-debug.log` |
| CAP | 1 | 2 |
| MAX_EXTENSIONS | 1 | 1 |
| PLANNER_AGENT | `outline-planner` | `detail-planner` |
| REVIEWER_AGENT | `outline-reviewer` | `detail-reviewer` |
| ACCEPTED_TRADEOFFS_FILE | `<PLANS_DIR>/<session-id>-intent.md` | `<PLANS_DIR>/<session-id>-outline.md` |
| NON_APPROVED_VERDICT | `MISSING_ALTERNATIVE:` | `NEEDS_REVISION` |

## Round Counter (ROUND_NUMBER)

`ROUND_NUMBER` is an orchestrator-tracked integer independent of `EXTENSIONS_USED`.

- Outline stage (CAP=1 / MAX_EXTENSIONS=1): ROUND_NUMBER is 1 on the initial review and 2 after a cap-menu `extend` / `AUTO_EXTEND`.
- Detail stage (CAP=2 / MAX_EXTENSIONS=1): ROUND_NUMBER reaches 2 on the second review within the same `EXTENSIONS_USED=0` budget; if the user extends, ROUND_NUMBER reaches 3 while `EXTENSIONS_USED=1`.

ROUND_NUMBER is NEVER `EXTENSIONS_USED + 1` — that derivation would mis-tag the second review of the detail stage as "round 1" and break the ESCALATE policy.

The per-stage wrapper script (`skills/make-{detail,outline}-plan/scripts/run-codex-review-loop.sh`) maintains ROUND_NUMBER on disk at `<PLANS_DIR>/drafts/<session-id>-<format>-round-number.txt` and increments it on each invocation. The file holds a single decimal integer `\n`-terminated. The wrapper passes `--round "$ROUND_NUMBER"` to `bin/run-codex-review-loop`. The file is deleted on exit 0 (APPROVED) or exit 2 (ESCALATE); it persists on exit 1 (CONTINUE) and exit 3.

## Concern-ID Ledger

`bin/run-codex-review-loop` maintains a per-session ledger at `<PLANS_DIR>/drafts/<session-id>-<format>-concern-ledger.txt`. The wrapper accepts a REQUIRED `--round N` argument (no default); the per-stage wrapper script always supplies it.

Each ledger line is pipe-delimited: `C<N>|<SEVERITY>|<full concern text>`. Full text is stored verbatim (no truncation).

- Round 1: assigns C1, C2, … to each concern; rewrites the forwarded reviewer output so concerns appear as `C<N>. [<SEV>] …`; writes ledger at the end of Round 1 processing.
- Round 2+: validates each `C<N>:` reference against the ledger; drops unknown IDs from forwarded output and emits a stderr warning `run-codex-review-loop: discarded new concern IDs in round N: C5, C6`; tallies residual severity from ledger for unresolved concerns.
- Missing ledger at Round 2: exits 4 with `ledger missing for round N` diagnostic (no silent recreation).

The Round 2+ codex prompt in `bin/review-plan-codex` is switched to Cn-reference form via `--round 2 --ledger <path>`. Applies to both `--format detail-plan` and `--format outline-plan`.

The ledger is deleted on terminal verdicts (APPROVED, ESCALATE) and persists across CONTINUE.

Within the wrapper, `bin/review-loop-verdict <round> <high> <medium> <low>` is invoked on every non-APPROVED reviewer verdict. Its decision overrides the raw reviewer verdict for exit-code selection: APPROVED→0, CONTINUE→1, ESCALATE→2.

## Per-round protocol

### a. Write draft

Write the planner's output to `DRAFT_FILE` via the Write tool.

### b/c/d. Invoke wrapper (single Bash call)

Each caller skill invokes its own per-skill extraction script (Bash tool):
- `skills/make-detail-plan/scripts/run-codex-review-loop.sh` (detail stage)
- `skills/make-outline-plan/scripts/run-codex-review-loop.sh` (outline stage)

Each script reads from the environment:
- Required: `AGENTS_CONFIG_DIR`, `SESSION_ID`, `PLANS_DIR`, `EXTENSIONS_USED`
- Optional: `CTX_SURVEY_CODE`, `CTX_SURVEY_HISTORY`, `CTX_CONCERNS_LOG` — each passed as `--context` when the file exists and is non-empty.

Exit codes pass through to the caller unchanged.

The wrapper internally:
1. Builds (per-stage, marker-gated at `<PLANS_DIR>/drafts/<session-id>-context.<FORMAT>.built`)
   the unified context at `<PLANS_DIR>/drafts/<session-id>-context.md` via
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

## Exit code → orchestrator action (SSOT) {#exit-code--orchestrator-action-ssot}

| Exit | Meaning | Orchestrator action |
|---|---|---|
| 0 | APPROVED | Return to caller for the write/confirm phase. |
| 1 | NON_APPROVED_VERDICT | Capture stdout to `RAW_FILE` (step d.1) → append round log + planner trailer to `CONCERNS_LOG` (step e) → re-invoke `PLANNER_AGENT`. |
| 2 | `FAILED — round cap reached` | Invoke cap-menu-dispatch (`skills/_shared/cap-menu-dispatch.md`). |
| 3 | **codex CLI unusable** (SKIPPED / FAILED-other / verdict malformed) | Append `<ISO-timestamp> round=<N> codex unavailable: <stderr>` to `DEBUG_LOG`; **silently launch `REVIEWER_AGENT` subagent**. Do NOT emit to chat. |
| 4 | **Wrapper / config / parser failure** (unset `AGENTS_CONFIG_DIR`, missing `core-principles.md`, missing arg, missing option value, missing binary, unrecognized status header, etc.) | **HALT with blocking error.** Surface the wrapper's stderr verbatim to the user. Do **NOT** fall back to `REVIEWER_AGENT` — exit 4 means the enforcement infrastructure itself is broken, and silent fallback would hide that. Append diagnostic to `DEBUG_LOG` then abort the skill. |

**Critical distinction:** exit 3 and exit 4 look superficially similar (neither produced a usable
verdict) but require opposite responses. Exit 3 is "codex was given a fair chance and could not
perform" → graceful degradation to the local reviewer is correct. Exit 4 is "the wrapper / config
/ parser is broken" → the local reviewer fallback would let the broken pipeline keep running
silently. Fix the underlying problem (set the env var, install the missing binary, restore
`core-principles.md`, etc.) and re-run.

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

- exit 0 → return to caller for the write/confirm phase.
- exit 1 → caller increments revision-round counter; re-invokes `PLANNER_AGENT`.
- exit 2 → caller invokes cap-menu-dispatch.
- exit 3 → caller silently falls back to `REVIEWER_AGENT` subagent.
- **exit 4 → caller HALTS with blocking error; no fallback.**

## Rationale: why a wrapper and not prose

The previous version of this protocol relied on prose ordering instructions. An orchestrator
that skipped step c (invoking `REVIEWER_AGENT` directly without ever calling `review-plan-codex`)
was not detected. The wrapper makes the codex path the only sanctioned mechanical entry point;
a `REVIEWER_AGENT` invocation is justified ONLY by exit 3, and exit 4 specifically forbids it.
