---
name: make-outline-plan
description: Propose 2-3 mutually-exclusive high-level approaches via outline-planner + outline-reviewer, then get user sign-off. Stage 2 of the three-stage planning pipeline. Outputs <session-id>-outline.md.
model: sonnet
---

Propose high-level approaches and get user sign-off before detailed planning.

Skip this stage when the entire Plan step is being skipped via `<<WORKFLOW_PLAN_NOT_NEEDED: ...>>`.
When `outline-planner` returns `SINGLE_APPROACH_JUSTIFIED`, skip the review/sign-off loop and proceed directly to `make-detail-plan`.

## Inputs

- `~/.claude/plans/<session-id>-intent.md` — output of `clarify-intent`; may be from a
  different session (cross-session carry-in is allowed)
- The session-id used for output files (`*-outline.md`) matches the intent file actually used

## Procedure

1. Locate the intent file:
   a. If `<session-id>-intent.md` exists, use it.
   b. Otherwise, list all `*-intent.md` files in `~/.claude/plans/`.
      - If exactly one exists, inform the user and use it.
      - If multiple exist, present them via `AskUserQuestion` and wait for the user to select one.
      - If none exist, abort: "clarify-intent must run before make-outline-plan. Run /clarify-intent first."
   c. Extract the session-id from the chosen file's name; use it for all subsequent output
      file paths (including `<session-id>-outline.md`).

2. Delegate to **outline-planner** subagent (`subagent_type: outline-planner`).
   Pass: the full contents of `<session-id>-intent.md` and the task context.

3. If outline-planner returns `SINGLE_APPROACH_JUSTIFIED: <reason>`:
   - Inform the user that only one approach is viable (citing the reason) and that the skill
     is proceeding directly to `/make-detail-plan`.
   - Write a minimal `<session-id>-outline.md` noting the justified single approach.
   - Proceed to emit the completion marker and stop.

4. If outline-planner returns `NEEDS_RESEARCH`:
   - Run `/deep-research` with the specified question.
   - Re-prompt outline-planner with the research findings. (Research budget: 2 rounds.)

5. **Review the approach with codex first, fall back to Claude if unavailable.**
   Write the outline-planner's output to the OS temp directory (NOT to `plans/`):
   - Windows: `%TEMP%\<session-id>-outline-draft.md`
   - POSIX:   `/tmp/<session-id>-outline-draft.md`
   Then: `review-plan-codex --input <temp-file> --format outline-plan`
   Parse the first line:
   - `## Codex Plan Review: PERFORMED` → extract verdict from inside fences:
     - `APPROVED` → proceed to step 7.
     - `MISSING_ALTERNATIVE: …` → use as the concern, proceed to step 6.
     - Anything else → **format malformed**: emit `> codex output malformed (could not parse verdict) — falling back to Claude reviewer for this round.` then launch `outline-reviewer` subagent.
   - `SKIPPED` / `FAILED` → **codex unavailable**: emit `> codex unavailable (<reason>) — falling back to Claude reviewer for this round.` then launch `outline-reviewer` subagent.

6. If verdict is `MISSING_ALTERNATIVE: <description>`:
   - Send the concern back to outline-planner for revision.
   - Re-review from step 5. Repeat for at most **1 revision round** (`revision_rounds`).
   - On cap: tell the user which concern is blocking and ask whether to add a missing
     alternative, approve as-is, or change the scope.

7. Once outline-reviewer returns `APPROVED`:
   - Present the approved approaches to the user via `AskUserQuestion` for selection.
   - One option must be "Pass all approaches to make-detail-plan without selecting" as a fallback.

8. Write the user's decision to `~/.claude/plans/<session-id>-outline.md` using the
   schema below. After writing, present the file to the user as a clickable link
   (do not paste the full content in chat):
   `[<session-id>-outline.md](~/.claude/plans/<session-id>-outline.md)`

## Output Schema (`<session-id>-outline.md`)

Write the file in Japanese (per `rules/language.md`) with the following sections:

- **Title**: "Confirmed Approach" + `<session-id>`
- **Adopted approach**: 1 paragraph + rationale for choosing it
- **Considered alternatives (rejected)**: one entry per rejected approach with reason
- **Reused existing utilities / building blocks**: list
- **Confirmed non-goals**: inherited from intent.md + any added during this stage

## Rules

- Orchestrator (main Claude) only summarizes each discussion round to the user —
  do not dump full subagent transcripts into the conversation.
- outline-planner and outline-reviewer are never shown implementation details —
  they work at the direction level only.
- `WORKFLOW_MARK_STEP_plan_complete` is NOT emitted here. It is emitted only by
  `make-detail-plan`.
- **One `AskUserQuestion` per run** — called only in step 7 (approach selection).
  Never pause for user confirmation during intermediate steps: Codex/reviewer
  revision rounds (step 6) or between-step summaries. Update files silently;
  inform the user with plain text only.

## Completion

After this skill:
1. Run: `echo "<<WORKFLOW_OUTLINE_PLAN_COMPLETE>>"`
2. Invoke `make-detail-plan` via the Skill tool.
