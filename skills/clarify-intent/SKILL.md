---
name: clarify-intent
description: Conduct a decision-tree interview with the user to lock in requirements, motivation, scope, and non-goals before planning. Step 1 of the workflow — mandatory pre-Plan requirements interview.
model: opus
---

IMPORTANT: This skill REQUIRES an interactive main Claude session. In non-interactive
contexts (`claude -p`, `/loop`, scheduled remote agents, subagent contexts),
`AskUserQuestion` will fail. On failure: output a diagnostic message naming the calling
context and stating that an interactive session is required, then hard-fail.
Do not silently proceed with default answers.

## Purpose

Front-load requirement clarification before any design or implementation work begins.
Inspired by Matt Pocock's `grill-me` skill (https://github.com/mattpocock/skills/tree/main/grill-me):
> "Interview relentlessly about every aspect of the plan until we reach a shared understanding.
> Walk down each branch of the design tree, resolving dependencies between decisions
> one-by-one. For each question, provide your recommended answer."

See `rules/plan-skip.md` for skip conditions.

## Procedure

1. Read the user's rough request. Identify the root of the decision tree: what is the single
   most important question whose answer unlocks all downstream questions?

2. Conduct a decision-tree interview using `AskUserQuestion`. Rules:
   - **1 question per invocation** — never batch multiple questions into one call.
   - Each option MUST include exactly one marked **(recommended)** option so the user can
     ratify the recommendation rather than having to invent an answer from scratch.
   - Walk in **dependency order** — only branch into sub-questions after a parent decision is
     confirmed.
   - **Maximum 5 rounds.** If understanding is still incomplete after 5 rounds, document the
     remaining ambiguities as constraints in the output and proceed.
   - If a question can be answered by exploring the codebase (e.g., "does X already exist?"),
     explore via Read/Grep/Glob instead of asking.

3. After the interview (or at the 5-round cap), write the agreed requirements to:
   ```
   ~/.claude/plans/<session-id>-intent.md
   ```
   Use the schema below. The `<session-id>` must be the current Claude session ID.
   Read `CLAUDE_SESSION_ID` from `$CLAUDE_ENV_FILE` if available; otherwise use a
   timestamp (`intent-YYYYMMDD-HHMMSS`) as fallback.

4. Present a one-paragraph summary of what was locked in.

5. Proceed to Plan step 2 — starting with Research (2a: `/survey-code` or `/deep-research`,
   unless not needed) then `/make-outline-plan`.

## Output Schema (`<session-id>-intent.md`)

Write the file in Japanese (per `rules/language.md`) with the following sections:

- **Title**: "Agreed Requirements" + `<session-id>`
- **Background / Motivation**: 1-2 paragraphs on why this task is needed
- **Scope**: what is included / what is excluded (non-goals)
- **Constraints**: list of constraints
- **Interview log**: each Q&A round recorded as "Q: ... A: ..."

## Completion

After this skill, run:
`echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"`
(This marks the `clarify_intent` workflow step complete.)
