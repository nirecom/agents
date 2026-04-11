---
name: make-plan
description: Produce an implementation plan via a planner/reviewer discussion loop, then get user approval.
model: opus
---

Produce an implementation plan via a planner/reviewer discussion loop.

## Procedure

1. Delegate initial drafting to the **planner** subagent (Agent tool, `subagent_type: planner`). Pass the full task context.
2. Pass the planner's draft to the **reviewer** subagent (`subagent_type: reviewer`).
3. If the reviewer returns `NEEDS_REVISION`, send the concerns back to the planner for revision, then re-review. Repeat.
4. **Escalate to the user** if the loop reaches **2 rounds** without approval. Summarize the unresolved disagreement and ask for guidance.
5. Once the reviewer returns `APPROVED`, enter plan mode and present the final plan to the user for approval.

## Skip Conditions

Skip the entire discussion loop when **both** of the following are true:
- The task is a single-file change
- No design decision is needed

In that case, draft the plan directly in the main conversation and present it for approval.

## Rules

- Read before planning — do not plan from assumptions
- Orchestrator (main Claude) only summarizes each discussion round to the user — do not dump full transcripts into the conversation
- Follow `rules/orthogonality.md` for cross-platform and naming consistency

## Completion

After completing this skill, run:
`node "$DOTFILES_DIR/claude-global/hooks/mark-step.js" $CLAUDE_SESSION_ID plan complete`
