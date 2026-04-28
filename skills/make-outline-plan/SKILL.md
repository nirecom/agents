---
name: make-outline-plan
description: Propose 2-3 mutually-exclusive high-level approaches via outline-planner + outline-reviewer, then get user sign-off. Stage 2 of the three-stage planning pipeline. Outputs <session-id>-approach.md.
model: opus
---

Propose high-level approaches and get user sign-off before detailed planning.

See `rules/plan-skip.md` for skip conditions. Skip this stage when:
- The entire Plan step is being skipped via `<<WORKFLOW_PLAN_NOT_NEEDED: ...>>`
- `outline-planner` emits `SINGLE_APPROACH_JUSTIFIED` (proceed directly to `make-detail-plan`)

## Inputs

- `~/.claude/plans/<session-id>-intent.md` — output of `clarify-intent` (MUST exist)
- The session-id is the same as used in the intent file

## Procedure

1. Verify `<session-id>-intent.md` exists. If not, abort with: "clarify-intent must run
   before make-outline-plan. Run /clarify-intent first."

2. Delegate to **outline-planner** subagent (`subagent_type: outline-planner`).
   Pass: the full contents of `<session-id>-intent.md` and the task context.

3. If outline-planner returns `SINGLE_APPROACH_JUSTIFIED: <reason>`:
   - Inform the user that only one approach is viable (citing the reason) and that the skill
     is proceeding directly to `/make-detail-plan`.
   - Write a minimal `<session-id>-approach.md` noting the justified single approach.
   - Proceed to emit the completion marker and stop.

4. If outline-planner returns `NEEDS_RESEARCH`:
   - Run `/deep-research` with the specified question.
   - Re-prompt outline-planner with the research findings. (Research budget: 2 rounds.)

5. **Review the approach with codex first, fall back to Claude if unavailable.**
   Write the outline-planner's output to a temp file, then:
   `review-plan-codex --input <temp-file> --format outline-plan`
   Parse the first line:
   - `## Codex Plan Review: PERFORMED` → extract verdict from inside fences:
     - `APPROVED` → proceed to step 7.
     - `MISSING_ALTERNATIVE: …` → use as the concern, proceed to step 6.
     - Anything else → **format malformed**: emit `> codex output malformed (could not parse verdict) — falling back to Claude reviewer for this round.` then launch `outline-reviewer` subagent.
   - `SKIPPED` / `FAILED` → **codex unavailable**: emit `> codex unavailable (<reason>) — falling back to Claude reviewer for this round.` then launch `outline-reviewer` subagent.

6. If verdict is `MISSING_ALTERNATIVE: <description>`:
   - Send the concern back to outline-planner for revision.
   - Re-review from step 5. Repeat for at most **2 revision rounds** (`revision_rounds`).
   - On cap: tell the user which concern is blocking and ask whether to add a missing
     alternative, approve as-is, or change the scope.

7. Once outline-reviewer returns `APPROVED`:
   - Present the approved approaches to the user via `AskUserQuestion` for selection.
   - One option must be "Pass all approaches to make-detail-plan without selecting" as a fallback.

8. Write the user's decision to `~/.claude/plans/<session-id>-approach.md` using the
   schema below.

## Output Schema (`<session-id>-approach.md`)

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

## Completion

After this skill:
1. Run: `echo "<<WORKFLOW_OUTLINE_PLAN_COMPLETE>>"`
2. Invoke `make-detail-plan` via the Skill tool (see `rules/plan-skip.md` for skip conditions).
