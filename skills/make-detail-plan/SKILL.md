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

Before any tool call below that references <PLANS_DIR>, run the following Bash command exactly once:

```bash
PLANS_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null \
              || printf '%s\n' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}")
printf 'PLANS_DIR=%s\n' "$PLANS_DIR"
```

Capture the printed absolute path and substitute it for every <PLANS_DIR>
placeholder in the remainder of this SKILL.md. Subagent prompts must receive
the resolved absolute path as a literal string (subagents cannot expand $VAR).
Reuse across all subsequent steps in this skill invocation — do not re-resolve.

Canonical documentation: skills/_shared/resolve-plans-dir.md.

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
   - Read `skills/judge-task-complexity/SKILL.md` to load the signal table.
   - Evaluate all signals against the full task context plus the contents of intent/outline files (if they exist). Do not short-circuit on the first match.
   - Apply the routing rule: 1+ signals → `opus`; 0 signals → `sonnet`; ambiguous → `opus`.
   - Emit in Claude text output (NOT Bash echo):
     > Model selected: **[opus|sonnet]** (signals: [comma-separated triggered signal IDs, or "none"])

4. Delegate initial drafting to the **planner** subagent (Agent tool, `subagent_type: detail-planner`, `model: <model from step 3>`).
   Pass the full task context **plus** the contents of the intent/approach files above.

5. **Review the draft with codex first, fall back to Claude if unavailable.**
   For each review round:
   a. Write the planner's draft using the Write tool to:
      `<PLANS_DIR>/drafts/<session-id>-detail-draft.md`


   b. **Build the review context file** (once per skill invocation; reuse across revision rounds).
      On the first review round only, determine which prior-stage files exist:
      - `<PLANS_DIR>/<session-id>-intent.md`
      - `<PLANS_DIR>/<session-id>-outline.md`

      Write `<PLANS_DIR>/drafts/<session-id>-context.md` with whichever sections apply
      (English headers mandatory, source comments mandatory):
      ```
      <!-- Source: <PLANS_DIR>/<session-id>-intent.md -->
      ## Section 1: Intent (User Requirements)

      <verbatim contents of <session-id>-intent.md>

      ---

      <!-- Source: <PLANS_DIR>/<session-id>-outline.md -->
      ## Section 2: Outline (Design Proposal)

      <verbatim contents of <session-id>-outline.md>
      ```
      Fallback rules:
      - If only the intent file exists: Section 1 only (no separator, no Section 2).
      - If only the outline file exists: Section 2 only (no separator, no Section 1).
      - If neither exists: skip context file; call review-plan-codex without `--context`.

      On revision rounds 2+, reuse the context file from round 1 — do not regenerate.
   c. Run via Bash:
      ```
      review-plan-codex --input <PLANS_DIR>/drafts/<session-id>-detail-draft.md \
                        --format detail-plan \
                        --session-id <session-id> \
                        --log-dir <PLANS_DIR>/drafts \
                        --cap 2 --max-extensions 2 --extensions-used $EXTENSIONS_USED \
                        --accepted-tradeoffs <PLANS_DIR>/<session-id>-outline.md \
                        [--context <PLANS_DIR>/drafts/<session-id>-context.md] \
                        [--context <PLANS_DIR>/drafts/<session-id>-concerns-log.md] \
                        --context "$AGENTS_CONFIG_DIR/rules/core-principles.md"
      ```
      `--accepted-tradeoffs` points to outline.md (SSOT carrying intent-stage + outline-stage tradeoffs after `make-outline-plan` Step 4a). `EXTENSIONS_USED` initialized to 0 at loop start.
      Omit `--context` args that point to files that don't exist yet.
   d. Parse the first line of stdout:
      - `## Codex Plan Review: PERFORMED` → read inside `<!-- begin-codex-output -->` fences.
        Extract the first non-blank line as the verdict token.
        - `APPROVED` (bare or `APPROVED <justification>`) → loop done, proceed to step 7.
        - `NEEDS_REVISION` → extract numbered concerns and proceed to step 5d.1 then 5e.
        - `FAILED — round cap reached` → step 6 (cap-menu dispatch).
        - Anything else → **format malformed**.
      - `## Codex Plan Review: SKIPPED — …` or `FAILED — …` (other reason) → **codex unavailable**.
      - **Format malformed**: append `<ISO-timestamp> round=<N> codex output malformed (could not parse verdict)` to `<PLANS_DIR>/drafts/<session-id>-detail-debug.log` via Bash `printf '%s\n' "..." >> <path>` and silently launch `detail-reviewer` subagent. Do NOT emit to chat.
      - **Codex unavailable**: append `<ISO-timestamp> round=<N> codex unavailable (<reason from status line>)` to `<PLANS_DIR>/drafts/<session-id>-detail-debug.log` and silently launch `detail-reviewer` subagent. Do NOT emit to chat.

   d.1. **Raw-codex persistence** (on NEEDS_REVISION):
      Extract content between `<!-- begin-codex-output -->` and `<!-- end-codex-output -->` from
      review-plan-codex stdout and write it to:
          `<PLANS_DIR>/drafts/<session-id>-codex-round-<N>-raw.md`
      Pass this path as a literal string in the next detail-planner invocation so the planner
      reads the raw codex output directly via Read tool.

   e. **Symmetric round log + planner-response trailer** (after every NEEDS_REVISION round):
      1. Append to `<PLANS_DIR>/drafts/<session-id>-concerns-log.md`:
         ```
         ## Round <N> (<ISO-timestamp>)
         Verdict: NEEDS_REVISION
         Concerns (verbatim from codex):
         <numbered concern lines>

         Planner's intended response (next round):
         <extracted verbatim from detail-planner's ROUND_RESPONSE trailer>
         ```
      2. Extract planner trailer per `agents/detail-planner.md` contract (`<!-- begin-planner-response -->` block).
      3. Codex receives this log via `--context` on the next round (Step 5c).
      4. Send concerns to detail-planner for revision (using the same model from step 3).

6. **Cap-reach dispatch** (review-plan-codex returned `FAILED — round cap reached`):
   a. `BUDGET_REMAINING = MAX_EXTENSIONS - EXTENSIONS_USED`
   b. Inspect `<session-id>-codex-round-<N>-raw.md` → derive `ALL_HIGH`.
   c. CC re-reads draft + concerns → `CC_AGREES_HIGH`.
   d. ```
      menu_json=$(review-loop-cap-menu \
        --budget-remaining $BUDGET_REMAINING \
        --all-high $ALL_HIGH --cc-agrees-high $CC_AGREES_HIGH \
        --label "Detail Plan Review")
      rc=$?
      ```
   e. Dispatch:
      - `rc==42` (AUTO_EXTEND)      → `EXTENSIONS_USED += 1`; loop to 5c
      - `rc==0`, user picks `land`   → Step 7
      - `rc==0`, user picks `adjust` → escalate to user with loop status / current plan / blocking concerns
      - `rc==0`, user picks `extend` → `EXTENSIONS_USED += 1`; loop to 5c
      - `rc==2` (arg error)          → halt; surface helper stderr

   When `BUDGET_REMAINING` reaches 0 (`EXTENSIONS_USED == MAX_EXTENSIONS`), helper renders only
   Land/Adjust (`.absolute_ceiling==true`); the next codex invocation fires `FAILED — absolute ceiling reached`.

   **Research/malformed-retry cap escalation**: if a research or malformed-retry cap is hit (see Research Escalation), message in this order:
   1. **Loop status** — which counter/cap was hit and how many rounds occurred.
   2. **The planner's current plan** — paste or closely summarize.
   3. **Blocking issues** — unresolved reviewer concerns or the pending research question.

7. Once the reviewer returns `APPROVED`, write the final plan to
   `<PLANS_DIR>/<session-id>-detail.md` (not draft). Then apply the
   confirm-plan protocol (`skills/_shared/confirm-plan.md`)
   using `CONFIRM_DETAIL` as the flag and `<session-id>-detail.md` as the artifact.
   - **Revise** (skill-specific): ask what to change, send feedback to the planner
     as a new revision request, then loop back to step 5a (re-draft → re-review →
     re-confirm). Each revision consumes `revision_rounds`.
   - On `OFF` path: emit `<<WORKFLOW_MARK_STEP_plan_complete>>` after the
     one-paragraph summary (per protocol Step 3). DO NOT present any path —
     the `show-plan-link.js` hook's `Plan file written:` line is the sole
     surfaced breadcrumb (per protocol Step 2).
   - On `ON` path (Proceed): emit `<<WORKFLOW_MARK_STEP_plan_complete>>` after confirmation.

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

## Skipping the Plan Step Entirely

The Skip Conditions above skip the planner/reviewer discussion loop but still
produce a plan. To skip the plan step itself (no plan at all), run:

`echo "<<WORKFLOW_PLAN_NOT_NEEDED: <reason>>"`

Use this only when the task is trivial enough that no written plan — not even
an informal one — is needed (e.g., a typo fix, a one-line config tweak).
Reason must be ≥3 non-space chars, not a placeholder, and contain no '>'.

Skipping research does NOT justify skipping the plan step.

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
1. Run: `echo "<<WORKFLOW_MARK_STEP_plan_complete>>"` (must be the ENTIRE Bash command — no pipes, no && chaining, no redirection)
2. Record the branching decision: consult `rules/branch.md` and `rules/worktree.md`, then run `echo "<<WORKFLOW_BRANCHING_COMPLETE: branch: <name>|worktree: <path>|main>>"`
3. Invoke `write-tests` via the Skill tool (or skip with `echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>"`).

