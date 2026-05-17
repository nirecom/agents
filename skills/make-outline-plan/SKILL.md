---
name: make-outline-plan
description: Propose 2-3 mutually-exclusive high-level approaches via outline-planner + outline-reviewer, then get user sign-off. Stage 2 of the three-stage planning pipeline. Outputs <session-id>-outline.md.
model: sonnet
---

Propose high-level approaches and get user sign-off before detailed planning.

Skip this stage when the entire Plan step is being skipped via `<<WORKFLOW_PLAN_NOT_NEEDED: ...>>`.
When `outline-planner` returns `SINGLE_APPROACH_JUSTIFIED`, skip the review/sign-off loop and proceed directly to `make-detail-plan`.

## Inputs

- `<PLANS_DIR>/<session-id>-intent.md` — output of `clarify-intent`; may be from a
  different session (cross-session carry-in is allowed)
- `<PLANS_DIR>/<session-id>-survey-code.md` — optional; output of `survey-code` (contains `## Verified Claims`)
- `<PLANS_DIR>/<session-id>-survey-history.md` — optional; output of `survey-history` (contains `## Verified Claims`)
- `state.premise_contradiction` (optional) — set by `WORKFLOW_PREMISE_FAIL` during Research stage.
  Sentinels in Step 0 are emitted directly by the orchestrator (Bash tool), never by any subagent.
- The session-id used for output files (`*-outline.md`) matches the intent file actually used

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

0. **Surface premise contradictions from Research artifacts.**

   0a. Determine session-id from `CLAUDE_SESSION_ID` env. Check whether both
       `<PLANS_DIR>/<session-id>-survey-code.md` and
       `<PLANS_DIR>/<session-id>-survey-history.md` exist.
       - If research was skipped (state.steps.research.status === "skipped"):
         skip Steps 0b–0d and proceed directly to Step 0e.
       - If one or both artifact files are missing AND research is not skipped:
         present a one-line warning in chat ("Research artifacts incomplete —
         running make-outline-plan without full premise verification") and proceed
         to Step 0e. Do not block.

   0b. Read the `## Verified Claims` section from each existing artifact. Collect
       all items with `verdict: contradicted`.

   0c. If any contradicted claims exist: orchestrator runs the following Bash call
       (description: "Record premise contradiction in workflow state"):
       `echo "<<WORKFLOW_PREMISE_FAIL: <one-line summary of contradictions>>>"`
       Then present a brief contradiction summary in chat and call AskUserQuestion:
       "(a) Revise intent.md and re-run /clarify-intent, or (b) Acknowledge and
       proceed (premise is outdated; I accept the risk)."

   0d. If user selects (b): orchestrator runs
       `echo "<<WORKFLOW_PREMISE_ACK>>"` (clears state.premise_contradiction).
       If user selects (a): abort the skill with instruction to re-run /clarify-intent.

   0e. Orchestrator runs `echo "<<WORKFLOW_MARK_STEP_research_complete>>"` to mark
       Research complete (aggregating survey-code and survey-history, which no longer
       emit this sentinel individually).
       Note: if deep-research was also run and already emitted research_complete,
       markStep is idempotent — this emit is harmless.

   Proceed to Step 1.

1. Locate the intent file:
   a. If `<session-id>-intent.md` exists, use it.
   b. Otherwise, list all `*-intent.md` files in `<PLANS_DIR>/`.
      - If exactly one exists, inform the user and use it.
      - If multiple exist, present them via `AskUserQuestion` and wait for the user to select one.
      - If none exist, abort: "clarify-intent must run before make-outline-plan. Run /clarify-intent first."
   c. Extract the session-id from the chosen file's name; use it for all subsequent output
      file paths (including `<session-id>-outline.md`).

2. Delegate to **outline-planner** subagent (`subagent_type: outline-planner`).
   Pass: the full contents of `<session-id>-intent.md` and the task context.

3. If outline-planner returns `SINGLE_APPROACH_JUSTIFIED: <reason>` (optionally followed by `DELIVERY_PLAN: <plan>` on the next line):
   - Parse both lines. If `DELIVERY_PLAN:` is absent (pre-change planner output), use the fallback text: "(not provided — planner pre-dates this convention)".
   - Inform the user that only one approach is viable (citing the reason) and that the skill
     is proceeding directly to `/make-detail-plan`.
   - Write a minimal `<session-id>-outline.md` noting the justified single approach and including
     a `## Delivery plan` section from the `DELIVERY_PLAN:` text (or the fallback text).
   - Apply the **full** `skills/_shared/confirm-plan.md` protocol (Steps 1+2+3)
     using `CONFIRM_OUTLINE` as the flag. Even with a single viable approach,
     the written artifact itself may need revision — protocol Step 3 covers that.
     If the user picks "Revise" in protocol Step 3, ask what to change, re-run
     outline-planner with the feedback, then loop back to Step 2 (delegation).
   - Proceed to emit `WORKFLOW_OUTLINE_PLAN_COMPLETE` (see Completion section)
     and stop.

4. If outline-planner returns `NEEDS_RESEARCH`:
   - Run `/deep-research` with the specified question.
   - Re-prompt outline-planner with the research findings. (Research budget: 2 rounds.)

5. **Review the approach with codex first, fall back to Claude if unavailable.**
   a. Write the outline-planner's output to the Claude-managed drafts directory
      (survives compaction; OS temp does not):
      `<PLANS_DIR>/drafts/<session-id>-outline-draft.md`


   b. **Build the review context file** (once per skill invocation; reuse across revision rounds).
      If `<PLANS_DIR>/<session-id>-intent.md` exists and the context file has not
      been built this run, write `<PLANS_DIR>/drafts/<session-id>-context.md`:
      ```
      <!-- Source: <PLANS_DIR>/<session-id>-intent.md -->
      ## Section 1: Intent (User Requirements)

      <verbatim contents of <session-id>-intent.md>
      ```
      If the intent file does not exist or is empty, skip the context file.
   c. Run via Bash:
      `review-plan-codex --input <PLANS_DIR>/drafts/<session-id>-outline-draft.md --format outline-plan --context <PLANS_DIR>/drafts/<session-id>-context.md --context "$AGENTS_CONFIG_DIR/rules/core-principles.md"`
      (omit `--context <PLANS_DIR>/drafts/<session-id>-context.md` when no context file was created in step b; always include the core-principles context).
   d. Parse the first line:
   - `## Codex Plan Review: PERFORMED` → extract verdict from inside fences:
     - `APPROVED` → proceed to step 7.
     - `MISSING_ALTERNATIVE: …` → use as the concern, proceed to step 6.
     - Anything else → **format malformed**: append `<ISO-timestamp> round=<N> codex output malformed (could not parse verdict)` to `<PLANS_DIR>/drafts/<session-id>-outline-debug.log` via Bash `printf '%s\n' "..." >> <path>` and silently launch `outline-reviewer` subagent. Do NOT emit to chat.
   - `SKIPPED` / `FAILED` → **codex unavailable**: append `<ISO-timestamp> round=<N> codex unavailable (<reason>)` to `<PLANS_DIR>/drafts/<session-id>-outline-debug.log` and silently launch `outline-reviewer` subagent. Do NOT emit to chat.

6. If verdict is `MISSING_ALTERNATIVE: <description>`:
   - Send the concern back to outline-planner for revision.
   - Re-review from step 5. Repeat for at most **1 revision round** (`revision_rounds`).
   - On cap: tell the user which concern is blocking and ask whether to add a missing
     alternative, approve as-is, or change the scope.

7. Once outline-reviewer returns `APPROVED`:
   Output a prose rationale summary in the main conversation — one paragraph per
   approach covering its rationale, trade-offs, and delivery plan. This preamble
   gives the user the context to choose. Do not write the preamble to outline.md.

   Then decide the chosen approach. Run via Bash:
     `bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off CONFIRM_OUTLINE on && echo OFF || echo ON'`
   - stdout `OFF`: set the chosen approach to "Pass all approaches to make-detail-plan without selecting". Do NOT call `AskUserQuestion`. Do NOT write the outline file yet — Step 8 handles the write.
   - stdout `ON`: present the approved approaches via `AskUserQuestion` for selection. One option must be "Pass all approaches to make-detail-plan without selecting" as a fallback. The user's selection is the chosen approach. Do NOT write the outline file yet — Step 8 handles the write.

   **AskUserQuestion content guard**: the `question` field must be a single short
   selection prompt (one sentence). Do NOT embed approach bodies, rationales, or
   trade-offs in `question` or option `description` — those belong in the prose
   preamble above. Each option's `description` is limited to a one-line summary
   of the approach (≤80 chars). The `AskUserQuestion` dialog is narrow and
   unreadable for long content; the preamble in main conversation is the venue
   for substance.

8. Write the chosen approach to `<PLANS_DIR>/<session-id>-outline.md` using
   the schema below. Then apply the **full** `skills/_shared/confirm-plan.md`
   protocol (Steps 1+2+3) using `CONFIRM_OUTLINE` as the flag.
   Step 7's `AskUserQuestion` was about *which approach to pick*; protocol Step 3
   asks about *the written artifact itself* (proceed/revise) — they are distinct
   user touchpoints. In ON mode, the user will see two `AskUserQuestion` calls
   per run, which is intentional.
   - **Revise** (skill-specific): ask what to change, re-run the outline-planner
     with the feedback, then loop back to Step 7.

## Output Schema (`<session-id>-outline.md`)

Write the file (per `rules/language.md`) with the following sections:

- **Title**: "Confirmed Approach" + `<session-id>`
- **Adopted approach**: 1 paragraph + rationale for choosing it
- **Delivery plan**: triage rationale / execution order / split policy for the adopted approach
- **Considered alternatives (rejected)**: one entry per rejected approach with reason
- **Reused existing utilities / building blocks**: list
- **Confirmed non-goals**: inherited from intent.md + any added during this stage

## Rules

- Orchestrator chat output during the discussion loop is restricted to:
  (a) one status line per round (`Round N: APPROVED` or `Round N: NEEDS_REVISION (proceeding)`)
  (b) NO path output — the `show-plan-link.js` PostToolUse hook emits the sole
      authoritative breadcrumb (`Plan file written: <abs-path>`) automatically.
      The orchestrator MUST NOT print, duplicate, translate, paraphrase, or
      reformat that path in any form. See `skills/_shared/confirm-plan.md` Step 2.
  (c) the prose rationale preamble emitted in step 7 before `AskUserQuestion`
  No per-round natural-language summaries, no codex/reviewer transcripts,
  no "falling back to Claude reviewer" notices in chat.
  Diagnostics go to <session-id>-outline-debug.log only.
- outline-planner and outline-reviewer are never shown implementation details —
  they work at the direction level only.
- `WORKFLOW_MARK_STEP_plan_complete` is NOT emitted here. It is emitted only by
  `make-detail-plan`.
- **Two `AskUserQuestion` calls per run in ON mode** — one for approach selection
  in step 7, one for artifact review in step 8 (via protocol Step 3). They are
  distinct user touchpoints: step 7 asks "which approach to pick" *before* the
  file is written; step 8 asks "proceed or revise" *after* reviewing the written
  file. In OFF mode neither AskUserQuestion fires.
- **AskUserQuestion is for choices, not content.** `question` is one sentence;
  option `description` is one line (≤80 chars). Approach bodies, rationales, and
  trade-offs go in the main-conversation prose preamble (step 7) — never inside
  `question` or option fields. The dialog UI is narrow; long content there is
  unreadable.
  Never pause for user confirmation during intermediate steps: Codex/reviewer
  revision rounds (step 6) or between-step summaries. Update files silently;
  inform the user with plain text only.

## Completion

After this skill:
1. Run: `echo "<<WORKFLOW_OUTLINE_PLAN_COMPLETE>>"`
2. Invoke `make-detail-plan` via the Skill tool.
