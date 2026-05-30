---
name: make-detail-plan
description: Stage 3 of three-stage planning pipeline. Produce a file-level implementation plan via detail-planner/detail-reviewer loop, then get user approval. Inputs are confirmed intent (<session-id>-intent.md) and outline (<session-id>-outline.md) from prior stages.
model: sonnet
---

Produce a detailed implementation plan via a planner/reviewer discussion loop.
The confirmed approach and requirements from `clarify-intent` and `make-outline-plan`
must be read and passed to the planner before drafting begins.

## Procedure

### Step 0 — Resolve <PLANS_DIR>

Apply `skills/_shared/resolve-plans-dir.md` once at the start of Procedure;
substitute the resolved absolute path for every `<PLANS_DIR>` placeholder
below. Reuse across all subsequent steps — do not re-resolve.

1. **Read prior-stage artifacts** (if they exist):
   - `<PLANS_DIR>/<session-id>-intent.md` — agreed requirements, scope, non-goals
   - `<PLANS_DIR>/<session-id>-outline.md` — confirmed design direction
   If neither file exists, proceed with the task context alone (no prior stages ran).

2. **Surface the delivery plan to the main conversation.**
   Read outline.md's `## Delivery plan` section (or the `Delivery plan:` field in the Adopted approach section).
   - If present and substantive: emit a one-paragraph summary in chat prefixed
     "Delivery plan (from outline stage):". This appears before the planner subagent runs.
   - If absent or "(not provided)": emit
     "Delivery plan: (not surfaced from outline — detail-planner will draft fresh as the first section of detail.md)."
   Plain text only — do not call AskUserQuestion and do not pause for confirmation.
   Use English terms only: "delivery plan", "progression", or "execution order".

3. **Determine the planner subagent's model**:
   - Read `skills/_shared/judge-task-complexity.md` to load the signal table.
   - Evaluate all signals against the full task context plus the contents of intent/outline files (if they exist). Do not short-circuit on the first match.
   - Apply the routing rule: 1+ signals → `opus`; 0 signals → `sonnet`; ambiguous → `opus`.
   - Emit in Claude text output (NOT Bash echo):
     > Model selected: **[opus|sonnet]** (signals: [comma-separated triggered signal IDs, or "none"])

4. Delegate initial drafting to the **planner** subagent (Agent tool, `subagent_type: detail-planner`, `model: <model from step 3>`).
   Pass the full task context **plus** the contents of the intent/approach files above.

5. **Codex review loop.** Follows `skills/_shared/codex-review-loop.md`
   (parameter values for the detail stage: FORMAT=detail-plan, CAP=2,
   MAX_EXTENSIONS=1, PLANNER_AGENT=detail-planner,
   REVIEWER_AGENT=detail-reviewer,
   ACCEPTED_TRADEOFFS_FILE=<PLANS_DIR>/<session-id>-outline.md,
   NON_APPROVED_VERDICT=NEEDS_REVISION).

   For each review round, invoke `"$AGENTS_CONFIG_DIR/skills/make-detail-plan/scripts/run-codex-review-loop.sh"`
   (Bash tool) with env vars exported: `AGENTS_CONFIG_DIR`, `SESSION_ID`, `PLANS_DIR`, `EXTENSIONS_USED` (required);
   `CTX_SURVEY_CODE`, `CTX_SURVEY_HISTORY`, `CTX_CONCERNS_LOG` (optional — passed as
   `--context` when the file exists and is non-empty). Exit codes pass through unchanged.

   Detail-stage caller paths:
   - RAW_FILE: `<PLANS_DIR>/drafts/<session-id>-codex-round-<N>-raw.md`
   - CONCERNS_LOG: `<PLANS_DIR>/drafts/<session-id>-concerns-log.md`
   - DEBUG_LOG: `<PLANS_DIR>/drafts/<session-id>-detail-debug.log`

   Exit code → action mapping: see the SSOT table in
   `skills/_shared/codex-review-loop.md` (#exit-code--orchestrator-action-ssot).

   **Exit 4 must NOT trigger `detail-reviewer` fallback** — halt the skill and
   surface the wrapper's stderr to the user. Only exit 3 falls back silently.

   The per-stage wrapper script maintains a `ROUND_NUMBER` counter on disk at `<PLANS_DIR>/drafts/<session-id>-detail-plan-round-number.txt`, independent of `EXTENSIONS_USED`. It increments on each wrapper invocation and is passed as `--round "$ROUND_NUMBER"` to `bin/run-codex-review-loop`. The counter is cleared on APPROVED (exit 0) or ESCALATE (exit 2), and persists on CONTINUE (exit 1). See `skills/_shared/codex-review-loop.md ## Round Counter (ROUND_NUMBER)` for the full contract.

6. **Cap-reach dispatch.** Apply `skills/_shared/cap-menu-dispatch.md` with these parameters:
   - LABEL: `"Detail Plan Review"`
   - RAW_FILE: `<PLANS_DIR>/drafts/<session-id>-codex-round-<N>-raw.md`
   - MAX_EXTENSIONS: 1

   Detail-specific dispatch override: `rc==0`, user picks `adjust` → escalate
   to the user with loop status / current plan / blocking concerns. All other
   outcomes route per the shared spec; on AUTO_EXTEND or `extend`, loop back
   into the step 5 review round.

   **Research/malformed-retry cap escalation**: if a research or malformed-retry cap is hit (see Research Escalation), message in this order:
   1. **Loop status** — which counter/cap was hit and how many rounds occurred.
   2. **The planner's current plan** — paste or closely summarize.
   3. **Blocking issues** — unresolved reviewer concerns or the pending research question.

7. Once the reviewer returns `APPROVED`, assemble the final plan to
   `<PLANS_DIR>/<session-id>-detail.md` via the shared helper. The helper
   carries the 3 mandatory sections (`## Issues`, `## Class members`,
   `## Accepted Tradeoffs`) verbatim from outline.md and uses the planner's
   draft as the body source.
   Run `"$AGENTS_CONFIG_DIR/skills/make-detail-plan/scripts/assemble-mandatory.sh"` (Bash tool) with env vars:
   `AGENTS_CONFIG_DIR`, `SESSION_ID`, `PLANS_DIR` (required).
   - Do NOT instruct the planner to author the 3 mandatory sections — the helper strips planner-authored copies before the final write.
   - Helper exit non-zero → re-prompt detail-planner once and re-assemble; second failure → halt with error.
   - `--source-kind outline` enforces hard-fail when outline.md is missing `## Class members` (post-#462 outline.md must always carry all 3 mandatory sections).

   Then apply the confirm-plan protocol (`skills/_shared/confirm-plan.md`)
   using `CONFIRM_DETAIL` as the flag and `<session-id>-detail.md` as the artifact.
   - **Revise** (skill-specific): ask what to change, send feedback to the planner
     as a new revision request, then loop back to step 5a (re-draft → re-review →
     re-confirm). Each revision consumes `revision_rounds`.
   - On `OFF` path: emit `<<WORKFLOW_MARK_STEP_detail_complete>>` after the
     one-paragraph summary (per protocol Step 3). DO NOT present any path —
     the `show-plan-link.js` hook's `Plan file written:` line is the sole
     surfaced breadcrumb (per protocol Step 2).
   - On `ON` path (Proceed): emit `<<WORKFLOW_MARK_STEP_detail_complete>>` after confirmation.

## Research Escalation

When the planner's reply starts with `NEEDS_RESEARCH` (first non-whitespace token), the orchestrator short-circuits before the reviewer and runs `/deep-research`. Format spec is in `planner.md`.

**Malformed** (missing/empty field, `skill:` ≠ `deep-research`): re-prompt once with a one-line diagnostic. Second malformed reply → escalate. Malformed retries do **not** consume `research_rounds`.

**Round counters** (per invocation, never reset):

| Counter | Cap |
|---|---|
| `revision_rounds` | 2 |
| `research_rounds` | 2 |
| `malformed_retries` | 1 |

`NEEDS_RESEARCH` does not consume `revision_rounds`. Allowed at any planner turn.

**Re-prompt template:**
```
Research complete.
Findings: <verbatim research output>

Original task: <original task prompt>
pending reviewer concerns (if any — empty on initial-draft turn): <forward verbatim or "(none)">

Incorporate findings under "## Research Findings (from this session)" and cite with [research: tag].
Now produce the full plan.
```

Subagent prompts may contain verbatim research (the "summarize to user" rule applies only to user-facing chat). Double-emit of `<<WORKFLOW_MARK_STEP_research_complete>>` is harmless (`markStep` is idempotent).

**On cap:** tell the user which budget was exhausted, how many times research ran, and the pending question. Ask: "Approve further research, provide the answer directly, or adjust scope?" Do not emit `WORKFLOW_MARK_STEP_plan_complete` on any escalation.

## Skip Conditions

Skip the entire discussion loop when **both** of the following are true:
- The task is a single-file change
- No design decision is needed

In that case, skip `judge-task-complexity` and draft the plan directly in the main conversation and present it for approval.

## Skipping This Stage

The Skip Conditions above skip the planner/reviewer discussion loop but still
produce a plan. To skip the detail stage itself (no detail plan), run:

`echo "<<WORKFLOW_DETAIL_NOT_NEEDED: <reason>>>"`

Use this only when the outline already provides file-level clarity (e.g., a
typo fix, a one-line config tweak, or when the outline stage already enumerated
the exact file edits).
Reason must be ≥3 non-space chars, not a placeholder, and contain no '>'.

Skipping research does NOT justify skipping the detail stage.

## Rules

- Read before planning — do not plan from assumptions
- The outline's Delivery plan must be surfaced in step 2 before the planner subagent runs. This is required, not optional.
- Orchestrator chat output during the discussion loop is restricted to:
  (a) one status line per round (`Round N: APPROVED` or `Round N: NEEDS_REVISION (proceeding)`)
  (b) NO path output — the `show-plan-link.js` PostToolUse hook emits the sole
      authoritative breadcrumb (`Plan file written: <abs-path>`) automatically.
      The orchestrator MUST NOT print, duplicate, translate, paraphrase, or
      reformat that path in any form. See `skills/_shared/confirm-plan.md` Step 2.
  (c) the `Delivery plan (...)` summary emitted by step 2 before the discussion loop begins
  Diagnostics go to <session-id>-detail-debug.log only.
- Follow `rules/core-principles.md`.
- **One user-facing confirmation per run** — the only user confirmation is the final plan approval in step 7. Never pause for user confirmation during intermediate revision rounds (steps 4–5): write draft files silently and inform the user with plain text only.

## Completion

After completing this skill:
1. Run: `echo "<<WORKFLOW_MARK_STEP_detail_complete>>"` (must be the ENTIRE Bash command — no pipes, no && chaining, no redirection)
2. Record the branching decision: consult `rules/branch.md` and `rules/worktree.md`, then run `echo "<<WORKFLOW_BRANCHING_COMPLETE: branch: <name>|worktree: <path>|main>>"`
3. Invoke `write-tests` via the Skill tool (or skip with `echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>"`).

