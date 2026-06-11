---
name: make-detail-plan
description: Stage 3 of three-stage planning pipeline. Produce a file-level implementation plan via detail-planner/detail-reviewer loop, then get user approval. Inputs are confirmed intent (<session-id>-intent.md) and outline (<session-id>-outline.md) from prior stages.
model: sonnet
---

Produce a detailed implementation plan via a planner/reviewer discussion loop.
Read intent.md + outline.md before drafting.

## Procedure

When a hook blocks a sanctioned command, a fallback path is taken, or any unexpected outcome occurs, report via supervisor-report — see rules/supervisor-reporting.md.

### Step MDP-1 — Resolve <PLANS_DIR> + read artifacts

Apply `skills/_shared/resolve-plans-dir.md` once; substitute the resolved absolute path for every `<PLANS_DIR>` below. Read `<PLANS_DIR>/<session-id>-intent.md` and `<PLANS_DIR>/<session-id>-outline.md` if present; otherwise proceed with task context alone.

### Step MDP-2 — Surface delivery plan

Run `bash "$AGENTS_CONFIG_DIR/skills/make-detail-plan/scripts/surface-delivery-plan.sh"` against outline.md.

### Step MDP-3 — Choose planner model

Read `skills/_shared/judge-task-complexity.md`; evaluate all signals against task + intent/outline content. Rule: 1+ signals → `opus`; 0 → `sonnet`; ambiguous → `opus`. Emit (Claude text, not Bash): `Model selected: **[opus|sonnet]** (signals: [ids or "none"])`.

### Step MDP-4 — Initial draft

Delegate to **planner** (Agent tool, `subagent_type: detail-planner`, `model: <from MDP-3>`). Pass task context + intent/outline contents.

### Step MDP-4a — Sentinel detection (adaptive skip)

If planner draft's first line contains `<<DETAIL_SKIPPABLE_BY_PLANNER:`: invoke MDP-5 with `MAX_EXTENSIONS=0` (one round, no extensions). APPROVED → MDP-7. HIGH/MEDIUM residual → ESCALATE with concerns + draft. Sentinel absent → MDP-5 unchanged.

### Step MDP-5 — Codex review loop

Follows `skills/_shared/codex-review-loop.md` with: FORMAT=detail-plan, CAP=2, MAX_EXTENSIONS=1, PLANNER_AGENT=detail-planner, REVIEWER_AGENT=detail-reviewer, ACCEPTED_TRADEOFFS_FILE=<PLANS_DIR>/<session-id>-outline.md, NON_APPROVED_VERDICT=NEEDS_REVISION.

Each round: invoke `"$AGENTS_CONFIG_DIR/skills/make-detail-plan/scripts/run-codex-review-loop.sh"` (Bash) with exported `AGENTS_CONFIG_DIR`, `SESSION_ID`, `PLANS_DIR`, `EXTENSIONS_USED` (required); `CTX_SURVEY_CODE`, `CTX_SURVEY_HISTORY`, `CTX_CONCERNS_LOG` (optional — passed as `--context` when present + non-empty). Exit codes pass through.

Detail-stage caller paths:
- RAW_FILE: `<PLANS_DIR>/drafts/<session-id>-codex-round-<N>-raw.md`
- CONCERNS_LOG: `<PLANS_DIR>/drafts/<session-id>-concerns-log.md`
- DEBUG_LOG: `<PLANS_DIR>/drafts/<session-id>-detail-debug.log`

Exit code → action: SSOT table in `skills/_shared/codex-review-loop.md`. **Exit 4 must NOT trigger `detail-reviewer` fallback** — halt + surface stderr. Only exit 3 falls back silently.

ROUND_NUMBER tracked at `<PLANS_DIR>/drafts/<session-id>-detail-plan-round-number.txt` (see codex-review-loop.md SSOT).

### Step MDP-6 — Cap-reach dispatch

Apply `skills/_shared/cap-menu-dispatch.md` with LABEL=`"Detail Plan Review"`, RAW_FILE=`<PLANS_DIR>/drafts/<session-id>-codex-round-<N>-raw.md`, MAX_EXTENSIONS=1.

Detail-specific override: `rc==0`, user picks `adjust` → escalate (loop status / current plan / blocking concerns). Other outcomes route per shared spec; AUTO_EXTEND / `extend` → loop back into MDP-5.

Research/malformed-retry cap escalation: see `bash "$AGENTS_CONFIG_DIR/skills/make-detail-plan/scripts/cap-escalation-message.sh"` for message order.

### Step MDP-7 — Assemble + confirm

On reviewer `APPROVED`: assemble `<PLANS_DIR>/<session-id>-detail.md` via the shared helper. Helper carries the 3 mandatory sections (`## Issues`, `## Class members`, `## Accepted Tradeoffs`) verbatim from outline.md; planner draft is the body source.

Run `"$AGENTS_CONFIG_DIR/skills/make-detail-plan/scripts/assemble-mandatory.sh"` (Bash) with env `AGENTS_CONFIG_DIR`, `SESSION_ID`, `PLANS_DIR` (required). Do NOT instruct planner to author the 3 mandatory sections — helper strips planner-authored copies. Helper exit non-zero → re-prompt planner once + re-assemble; second failure → halt. `--source-kind outline` hard-fails when outline.md lacks `## Class members`.

Apply confirm-plan protocol (`skills/_shared/confirm-plan.md`) with `CONFIRM_DETAIL` flag and `<session-id>-detail.md` artifact.
- **Revise** (skill-specific): ask what to change, send feedback to planner as new revision request, loop to MDP-5 (re-draft → re-review → re-confirm). Each revision consumes `revision_rounds`.
- `OFF` path: emit `<<WORKFLOW_MARK_STEP_detail_complete>>` after one-paragraph summary (protocol Step 3). DO NOT present any path — `show-plan-link.js`'s `Plan file written:` line is the sole breadcrumb (protocol Step 2).
- `ON` path: emit `echo "<<WORKFLOW_CONFIRM_DETAIL: <one-line summary>>>"` per protocol Step 3 — co-emit `<<WORKFLOW_MARK_STEP_detail_complete>>` as a subsequent Bash call in the same response, so Allow continues straight to MDP-completion (see confirm-plan.md Step 3 co-emission).

## Research Escalation

Planner reply starting with `NEEDS_RESEARCH` (first non-whitespace token) short-circuits before reviewer + runs `/deep-research`. Format spec: `planner.md`.

**Malformed** (missing/empty field, `skill:` ≠ `deep-research`): re-prompt once with one-line diagnostic. Second malformed → escalate. Malformed retries do NOT consume `research_rounds`.

Round counters (revision: 2, research: 2, malformed_retries: 1) — see codex-review-loop.md SSOT. `NEEDS_RESEARCH` does NOT consume `revision_rounds`; allowed at any planner turn.

Re-prompt template: run `bash "$AGENTS_CONFIG_DIR/skills/make-detail-plan/scripts/research-reprompt.sh"` for the template.

Subagent prompts may contain verbatim research (summarize-to-user applies to user-facing chat only). Double-emit of `<<WORKFLOW_MARK_STEP_research_complete>>` is harmless (`markStep` idempotent).

On cap: tell user which budget exhausted, how many times research ran, the pending question. Ask: "Approve further research, provide the answer directly, or adjust scope?" Do not emit `WORKFLOW_MARK_STEP_plan_complete` on escalation.

## Skip Conditions / Skipping This Stage

See `bash "$AGENTS_CONFIG_DIR/skills/make-detail-plan/scripts/skip-conditions.sh"`.

## Rules

- Read intent/outline before planning — never plan from assumptions.
- Outline's Delivery plan must be surfaced in MDP-2 before planner subagent runs (required).
- Orchestrator chat during discussion loop is restricted to: (a) one status line per round (`Round N: APPROVED|NEEDS_REVISION (proceeding)`); (b) NO path output — `show-plan-link.js` PostToolUse hook is the sole authoritative breadcrumb (do not print/duplicate/translate/paraphrase/reformat); (c) the `Delivery plan (...)` summary from MDP-2. Diagnostics → `<session-id>-detail-debug.log`.
- Follow `rules/core-principles.md`.
- **One user-facing confirmation per run** — only the final plan approval in MDP-7. Never pause during intermediate revision rounds (MDP-4..5): write drafts silently, inform user with plain text only.
- Planner + reviewer apply `skills/_shared/priority-hierarchy.md` — codex/reviewer concerns must not override approved intent.md / outline.md decisions.

## Completion

1. Run: `echo "<<WORKFLOW_MARK_STEP_detail_complete>>"` (ENTIRE Bash command — no pipes / && / redirection).
2. Record branching: consult `rules/branch.md` + `rules/worktree.md`, run `echo "<<WORKFLOW_BRANCHING_COMPLETE: branch: <name>|worktree: <path>|main>>"`.
3. Invoke `write-tests` via Skill tool (or skip with `echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>"`).
