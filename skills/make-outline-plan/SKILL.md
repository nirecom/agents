---
name: make-outline-plan
description: Propose 2-3 mutually-exclusive high-level approaches via outline-planner + outline-reviewer, then get user sign-off. Stage 2 of the three-stage planning pipeline. Outputs <session-id>-outline.md.
model: sonnet
---

Propose high-level approaches and get user sign-off before detailed planning.

Skip when the entire Plan step is skipped via `<<WORKFLOW_PLAN_NOT_NEEDED: ...>>`.
When `outline-planner` returns `SINGLE_APPROACH_JUSTIFIED`, skip the review/sign-off loop and proceed directly to `make-detail-plan`.

## Inputs

- `<PLANS_DIR>/<session-id>-intent.md` — output of `clarify-intent` (cross-session carry-in allowed)
- `<PLANS_DIR>/<session-id>-survey-{code,history}.md` — optional; contain `## Verified Claims`
- `state.premise_contradiction` — optional; set by `WORKFLOW_PREMISE_FAIL` during Research stage
- All sentinels in Step 0 are emitted by the orchestrator (Bash tool), never by a subagent.
- Session-id used for `*-outline.md` matches the intent file actually used.

## Procedure

### Step 0 — Resolve <PLANS_DIR>

Apply `skills/_shared/resolve-plans-dir.md` once; substitute the resolved absolute path for every `<PLANS_DIR>` below. Reuse across steps.

0. **Surface premise contradictions** from Research artifacts.
   0a. Determine session-id from `CLAUDE_SESSION_ID` env (Step 1 has not run yet — this lookup precedes intent-file resolution).
       - `state.steps.research.status === "skipped"` → skip to 0e.
       - One/both `<session-id>-survey-{code,history}.md` missing AND research not skipped → warn once in chat ("Research artifacts incomplete — proceeding without full premise verification") and continue to 0e. Do not block.
   0b. Read `## Verified Claims` from each existing artifact; collect items with `verdict: contradicted`.
   0c. Any contradicted claims:
     1. Emit `<<WORKFLOW_PREMISE_FAIL: <one-line summary>>>` (Bash description: "Record premise contradiction in workflow state").
     2. Present a brief contradiction summary; `AskUserQuestion`: (a) revise intent.md and re-run `/clarify-intent`, (b) acknowledge and proceed.
   0d. (a) → abort the skill with instruction to re-run `/clarify-intent`. (b) → emit `<<WORKFLOW_PREMISE_ACK>>` (clears `state.premise_contradiction`).
   0e. Emit `<<WORKFLOW_MARK_STEP_research_complete>>` to mark Research complete (aggregating survey-code and survey-history, which no longer emit it individually; deep-research's emit, if any, is idempotent).

1. Locate the intent file:
   a. `<session-id>-intent.md` exists → use it.
   b. Otherwise list `<PLANS_DIR>/*-intent.md`. Exactly one → inform the user and use it; multiple → `AskUserQuestion` to select one; none → abort with "clarify-intent must run before make-outline-plan. Run /clarify-intent first."
   c. Extract session-id from the chosen file's name; use it for all subsequent output paths.

2. Delegate to **outline-planner** subagent (`subagent_type: outline-planner`). Pass full contents of `<session-id>-intent.md` and task context.

3. If outline-planner returns `SINGLE_APPROACH_JUSTIFIED: <reason>` (optionally `DELIVERY_PLAN: <plan>` on next line):
   - Parse both lines. If `DELIVERY_PLAN:` is absent (pre-change planner output), use the fallback text "(not provided — planner pre-dates this convention)".
   - Inform user that only one approach is viable (citing the reason) and that the skill is proceeding directly to `/make-detail-plan`.
   - Write a minimal planner output containing the H1, the approved single approach text, and a `## Delivery plan` section from the `DELIVERY_PLAN:` text (or fallback) to `<PLANS_DIR>/drafts/<session-id>-outline-draft.md`. Do NOT author `## Issue` / `## Class members` / `## Accepted Tradeoffs` — they are machine-injected next.
   - Assemble the final outline.md by invoking the shared helper (same call as the normal path in Step 4a):
     ```bash
     "$AGENTS_CONFIG_DIR/skills/_shared/assemble-mandatory.sh" --source-kind intent \
       "<PLANS_DIR>/<session-id>-intent.md" \
       "<PLANS_DIR>/drafts/<session-id>-outline-draft.md" \
       "<PLANS_DIR>/<session-id>-outline.md"
     ```
   - Apply the full `skills/_shared/confirm-plan.md` protocol (Steps 1+2+3) using `CONFIRM_OUTLINE`. Even single viable approach may need artifact revision — protocol Step 3 covers that. Revise → ask what to change, re-run outline-planner, loop back to Step 2.
   - Emit `WORKFLOW_OUTLINE_PLAN_COMPLETE` (Completion) and stop.

4. If outline-planner returns `NEEDS_RESEARCH`: run `/deep-research`, then re-prompt outline-planner with findings. Research budget: 2 rounds.

4a. **Mandatory sections carry-forward (machine-injected — do not instruct planner to author them):**
   After outline-planner returns its draft (initial or revised round), the orchestrator mechanically injects the 3 mandatory sections (`## Issue`, `## Class members`, `## Accepted Tradeoffs`) from intent.md into the final outline.md via the shared helper:
   ```bash
   "$AGENTS_CONFIG_DIR/skills/_shared/assemble-mandatory.sh" --source-kind intent \
     "<PLANS_DIR>/<session-id>-intent.md" \
     "<PLANS_DIR>/drafts/<session-id>-outline-draft.md" \
     "<PLANS_DIR>/<session-id>-outline.md"
   ```
   - The helper extracts the 3 sections from intent.md with headers, strips any planner-authored copies plus the planner's H1 from the draft, and writes the assembled outline.md.
   - Helper exit non-zero → re-prompt outline-planner once and re-assemble; second failure → halt the loop.
   - Mandatory sections are machine-injected — do NOT instruct planner to author them or duplicate intent.md's wording. Planner-authored copies will be stripped before the final write.
   - Legacy intent.md (pre-#462) lacking `## Class members` is handled by the helper's soft-fail path (auto-injects a stub) — no orchestrator action needed.

   `EXTENSIONS_USED` counter initialized to 0 at loop start.

5. **Codex review loop.** Apply `skills/_shared/codex-review-loop.md` with these parameters:
   - FORMAT: `outline-plan`
   - DRAFT_FILE: `<PLANS_DIR>/drafts/<session-id>-outline-draft.md`
   - RAW_FILE: `<PLANS_DIR>/drafts/<session-id>-outline-codex-round-<N>-raw.md`
   - CONCERNS_LOG: `<PLANS_DIR>/drafts/<session-id>-outline-concerns-log.md`
   - DEBUG_LOG: `<PLANS_DIR>/drafts/<session-id>-outline-debug.log`
   - CAP: 1
   - MAX_EXTENSIONS: 1
   - PLANNER_AGENT: `outline-planner`
   - REVIEWER_AGENT: `outline-reviewer`
   - ACCEPTED_TRADEOFFS_FILE: `<PLANS_DIR>/<session-id>-intent.md`
   - NON_APPROVED_VERDICT: `MISSING_ALTERNATIVE`

   Outcomes:
   - APPROVED → step 7.
   - MISSING_ALTERNATIVE → loop (revision budget: 1 round). On budget exhaustion before cap-menu fires, tell user which concern is blocking and ask: add missing alternative / approve as-is / change scope.
   - `FAILED — round cap reached` → step 6.

6. **Cap-reach dispatch.** Apply `skills/_shared/cap-menu-dispatch.md` with:
   - LABEL: `"Outline Plan Review"`
   - RAW_FILE: `<PLANS_DIR>/drafts/<session-id>-outline-codex-round-<N>-raw.md`
   - MAX_EXTENSIONS: 1

   Override: `rc==0` + user picks `adjust` → halt and re-run `/clarify-intent` (not generic user-escalation). AUTO_EXTEND / `extend` → loop back into step 5.

7. On `APPROVED`:
   Output a prose rationale summary in main conversation — one paragraph per approach (rationale + trade-offs + delivery plan). Do NOT write this preamble to outline.md.

   Decide the chosen approach:
   `bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off CONFIRM_OUTLINE on && echo OFF || echo ON'`
   - `OFF` → chosen approach = "Pass all approaches to make-detail-plan without selecting". Do NOT call `AskUserQuestion`.
   - `ON` → present approved approaches via `AskUserQuestion`. One option MUST be "Pass all approaches to make-detail-plan without selecting".

   Step 8 handles the file write — do NOT write here.

8. Write the chosen approach to `<PLANS_DIR>/<session-id>-outline.md` per the Output Schema. Apply the full `skills/_shared/confirm-plan.md` protocol (Steps 1+2+3) using `CONFIRM_OUTLINE`. Revise → ask what to change, re-run outline-planner, loop back to Step 7.

## Output Schema (`<session-id>-outline.md`)

The file (per `rules/language.md`) contains:

- **Title** (H1): "Confirmed Approach" + `<session-id>`
- **Mandatory sections** (machine-injected by `skills/_shared/assemble-mandatory.sh`, not authored by planner):
  - `## Issue` — present only when intent.md had one
  - `## Class members`
  - `## Accepted Tradeoffs`
- **Planner-authored body sections** (drafted by outline-planner):
  - **Adopted approach**: 1 paragraph + rationale for choosing it
  - **Delivery plan**: triage rationale / execution order / split policy for the adopted approach
  - **Considered alternatives (rejected)**: one entry per rejected approach with reason
  - **Reused existing utilities / building blocks**: list
  - **Confirmed non-goals**: inherited from intent.md + any added during this stage

## Rules

- **Chat output during the discussion loop** is restricted to:
  (a) one status line per round (`Round N: APPROVED` / `Round N: NEEDS_REVISION (proceeding)`)
  (b) NO path output — `show-plan-link.js` PostToolUse hook emits the sole authoritative breadcrumb. Orchestrator MUST NOT print, duplicate, translate, paraphrase, or reformat the path. See `skills/_shared/confirm-plan.md` Step 2.
  (c) the prose rationale preamble emitted in step 7 before `AskUserQuestion`
  No per-round natural-language summaries, no codex/reviewer transcripts, no "falling back to Claude reviewer" notices in chat. Diagnostics go to `<session-id>-outline-debug.log` only.
- outline-planner and outline-reviewer never see implementation details — direction-level only.
- `WORKFLOW_MARK_STEP_plan_complete` is NOT emitted here; only `make-detail-plan` emits it.
- **Two `AskUserQuestion` calls per run in ON mode** — step 7 (approach selection, before file write) and step 8 (artifact review via protocol Step 3, after write). OFF mode fires neither.
- **`AskUserQuestion` is for choices, not content.** `question` is one sentence; option `description` ≤80 chars. Approach bodies/rationales/trade-offs go in the step 7 prose preamble — never inside dialog fields. The dialog UI is narrow; long content there is unreadable.
- Never pause for user confirmation during intermediate steps (codex/reviewer revision rounds in step 6, between-step summaries). Update files silently; inform the user with plain text only.

## Completion

1. `echo "<<WORKFLOW_OUTLINE_PLAN_COMPLETE>>"`
2. Invoke `make-detail-plan` via the Skill tool.
