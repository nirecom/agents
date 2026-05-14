---
name: make-outline-plan
description: Propose 2-3 mutually-exclusive high-level approaches via outline-planner + outline-reviewer, then get user sign-off. Stage 2 of the three-stage planning pipeline. Outputs <session-id>-outline.md.
model: sonnet
---

Propose high-level approaches and get user sign-off before detailed planning.

Skip this stage when the entire Plan step is being skipped via `<<WORKFLOW_PLAN_NOT_NEEDED: ...>>`.
When `outline-planner` returns `SINGLE_APPROACH_JUSTIFIED`, skip the review/sign-off loop and proceed directly to `make-detail-plan`.

## Inputs

- `~/.workflow-plans/<session-id>-intent.md` — output of `clarify-intent`; may be from a
  different session (cross-session carry-in is allowed)
- The session-id used for output files (`*-outline.md`) matches the intent file actually used

## Procedure

1. Locate the intent file:
   a. If `<session-id>-intent.md` exists, use it.
   b. Otherwise, list all `*-intent.md` files in `~/.workflow-plans/`.
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
   - Proceed to emit the completion marker and stop.

4. If outline-planner returns `NEEDS_RESEARCH`:
   - Run `/deep-research` with the specified question.
   - Re-prompt outline-planner with the research findings. (Research budget: 2 rounds.)

5. **Review the approach with codex first, fall back to Claude if unavailable.**
   a. Write the outline-planner's output to the Claude-managed drafts directory
      (survives compaction; OS temp does not):
      `~/.workflow-plans/drafts/<session-id>-outline-draft.md`


   b. **Build the review context file** (once per skill invocation; reuse across revision rounds).
      If `~/.workflow-plans/<session-id>-intent.md` exists and the context file has not
      been built this run, write `~/.workflow-plans/drafts/<session-id>-context.md`:
      ```
      <!-- Source: ~/.workflow-plans/<session-id>-intent.md -->
      ## Section 1: Intent (User Requirements)

      <verbatim contents of <session-id>-intent.md>
      ```
      If the intent file does not exist or is empty, skip the context file.
   c. Run via Bash:
      `review-plan-codex --input ~/.workflow-plans/drafts/<session-id>-outline-draft.md --format outline-plan --context ~/.workflow-plans/drafts/<session-id>-context.md`
      (omit `--context ~/.workflow-plans/drafts/<session-id>-context.md` when no context file was created in step b).
   d. Parse the first line:
   - `## Codex Plan Review: PERFORMED` → extract verdict from inside fences:
     - `APPROVED` → proceed to step 7.
     - `MISSING_ALTERNATIVE: …` → use as the concern, proceed to step 6.
     - Anything else → **format malformed**: append `<ISO-timestamp> round=<N> codex output malformed (could not parse verdict)` to `~/.workflow-plans/drafts/<session-id>-outline-debug.log` via Bash `printf '%s\n' "..." >> <path>` and silently launch `outline-reviewer` subagent. Do NOT emit to chat.
   - `SKIPPED` / `FAILED` → **codex unavailable**: append `<ISO-timestamp> round=<N> codex unavailable (<reason>)` to `~/.workflow-plans/drafts/<session-id>-outline-debug.log` and silently launch `outline-reviewer` subagent. Do NOT emit to chat.

6. If verdict is `MISSING_ALTERNATIVE: <description>`:
   - Send the concern back to outline-planner for revision.
   - Re-review from step 5. Repeat for at most **1 revision round** (`revision_rounds`).
   - On cap: tell the user which concern is blocking and ask whether to add a missing
     alternative, approve as-is, or change the scope.

7. Once outline-reviewer returns `APPROVED`:
   Before calling `AskUserQuestion`, output a prose rationale summary in the main conversation —
   one paragraph per approach covering its rationale, trade-offs, and delivery plan.
   This preamble gives the user the context to choose. Do not write the preamble to outline.md.

   Run via Bash:
     `bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off CONFIRM_OUTLINE on && echo OFF || echo ON'`
   - stdout `OFF`: write the outline file using the "Pass all approaches to make-detail-plan without selecting" default. Print a one-paragraph summary of the approved approaches and the link to <session-id>-outline.md. Do NOT call `AskUserQuestion`.
   - stdout `ON`: present the approved approaches via `AskUserQuestion` for selection (existing behavior). One option must be "Pass all approaches to make-detail-plan without selecting" as a fallback.

8. Write the user's decision to `~/.workflow-plans/<session-id>-outline.md` using the
   schema below. Then apply the confirm-plan protocol
   (`skills/_shared/confirm-plan.md`) using `CONFIRM_OUTLINE` as the flag
   and `<session-id>-outline.md` as the artifact.
   - **Revise** (skill-specific): ask what to change, re-run the outline-planner with
     the feedback, then loop back to the protocol's Step 1.

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
  (b) the final clickable link to <session-id>-outline.md
  (c) the prose rationale preamble emitted in step 7 before `AskUserQuestion`
  No per-round natural-language summaries, no codex/reviewer transcripts,
  no "falling back to Claude reviewer" notices in chat.
  Diagnostics go to <session-id>-outline-debug.log only.
- outline-planner and outline-reviewer are never shown implementation details —
  they work at the direction level only.
- `WORKFLOW_MARK_STEP_plan_complete` is NOT emitted here. It is emitted only by
  `make-detail-plan`.
- **One `AskUserQuestion` per run** — called only in step 7 (approach selection).
  A prose rationale summary before the call is required (item (c) above) and does not count as an additional user confirmation.
  Never pause for user confirmation during intermediate steps: Codex/reviewer
  revision rounds (step 6) or between-step summaries. Update files silently;
  inform the user with plain text only.

## Completion

After this skill:
1. Run: `echo "<<WORKFLOW_OUTLINE_PLAN_COMPLETE>>"`
2. Invoke `make-detail-plan` via the Skill tool.
