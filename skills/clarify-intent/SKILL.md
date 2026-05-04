---
name: clarify-intent
description: Conduct a decision-tree interview with the user to lock in requirements, motivation, scope, and non-goals before planning.
model: sonnet
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

## Skip Conditions

Skip this skill and emit `echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: <reason>>>"` when intent is already clear:
- A `*-intent.md` from a prior session already covers this request
- The request is self-contained and unambiguous (single-sentence, no design decision needed)

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
   Use the Write tool directly — do NOT run mkdir first (Write creates parent directories automatically).
   Use the schema below. The `<session-id>` must be the current Claude session ID.
   Read `CLAUDE_SESSION_ID` from `$CLAUDE_ENV_FILE` if available; otherwise use a
   timestamp (`intent-YYYYMMDD-HHMMSS`) as fallback.

4. Present a one-paragraph summary of what was locked in.

5. Confirm the summary via `AskUserQuestion` before proceeding:
   - One option marked **(recommended)**: proceed to planning.
   - At least one revision option: update intent.md based on user input, then re-present.
   - Maximum 1 revision round at this gate; deeper changes resolve in later planning stages.

6. Proceed to Plan step 2 — starting with Research (2a: `/survey-code` or `/deep-research`,
   unless not needed) then `/make-outline-plan`.

## Output Schema

Write one file in Japanese (per `rules/language.md`):

### `<session-id>-intent.md`

- **Title**: "Agreed Requirements" + `<session-id>`
- **Background / Motivation**: 1-2 paragraphs on why this task is needed
- **Scope**: what is included / what is excluded (non-goals)
- **Constraints**: list of constraints
- **Interview Log** (optional): each Q&A round recorded as "Q: ... A: ..."

## Completion

After this skill:
1. Run: `echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"` (hook will return the next-step hint, and the early gate disengages)
2. Create a TodoWrite checklist with the remaining 9 workflow steps (mark `clarify_intent` as completed):
   - Research (`/survey-code` or `/deep-research`, or skip with NOT_NEEDED)
   - Plan (`/make-outline-plan` → `/make-detail-plan`, or skip with NOT_NEEDED)
   - Branching decision (consult `rules/branch.md` + `rules/worktree.md`)
   - Write tests (`/write-tests`, or skip with NOT_NEEDED)
   - Code (present diff in chat before Edit)
   - Run tests + Security review + Codex review in parallel
   - Docs (`/update-docs`)
   - User verification (`echo "<<WORKFLOW_USER_VERIFIED>>"`)
   - Commit + Cleanup (`/commit-push`, then worktree-end / branch-delete / skip per branching decision)
3. Invoke `survey-code` or `deep-research` via the Skill tool if needed
   (or skip with `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>"`), then invoke `make-outline-plan`.
