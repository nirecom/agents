---
name: make-detail-plan
description: Stage 3 of three-stage planning pipeline. Produce a file-level implementation plan via detail-planner/detail-reviewer loop, then get user approval. Inputs are confirmed intent (<session-id>-intent.md) and outline (<session-id>-outline.md) from prior stages.
model: sonnet
---

Produce a detailed implementation plan via a planner/reviewer discussion loop.
The confirmed approach and requirements from `clarify-intent` and `make-outline-plan`
must be read and passed to the planner before drafting begins.

## Procedure

1. **Read prior-stage artifacts** (if they exist):
   - `~/.claude/plans/<session-id>-intent.md` — agreed requirements, scope, non-goals
   - `~/.claude/plans/<session-id>-outline.md` — confirmed design direction
   If neither file exists, proceed with the task context alone (no prior stages ran).

2. Delegate initial drafting to the **planner** subagent (Agent tool, `subagent_type: detail-planner`).
   Pass the full task context **plus** the contents of the intent/approach files above.
3. **Review the draft with codex first, fall back to Claude if unavailable.**
   For each review round:
   a. Write the planner's draft to `~/.claude/plans/<session-id>-detail-draft.md`.
   b. Run via Bash: `review-plan-codex --input ~/.claude/plans/<session-id>-detail-draft.md --format detail-plan [--context ~/.claude/plans/<session-id>-outline.md]`
      (omit `--context` if the outline file does not exist)
   c. Parse the first line of stdout:
      - `## Codex Plan Review: PERFORMED` → read inside `<!-- begin-codex-output -->` fences.
        Extract the first non-blank line as the verdict token.
        - `APPROVED` → loop done, proceed to step 6.
        - `NEEDS_REVISION` → extract numbered concerns (lines starting `1.`, `2.`, …) and treat as reviewer concerns. If no concerns parse, treat as malformed (below).
        - Anything else → **format malformed**.
      - `## Codex Plan Review: SKIPPED — …` or `FAILED — …` → **codex unavailable**.
      - **Format malformed**: emit `> codex output malformed (could not parse verdict) — falling back to Claude reviewer for this round.` then launch `detail-reviewer` subagent.
      - **Codex unavailable**: emit `> codex unavailable (<reason from status line>) — falling back to Claude reviewer for this round.` then launch `detail-reviewer` subagent.
   d. Whether from codex or Claude reviewer: if result is `NEEDS_REVISION`, send concerns back to planner for revision, then repeat from step 3a. Each round consumes `revision_rounds`.
4. **Escalate to the user** if the loop reaches **2 revision rounds** without approval, or a research/malformed-retry cap is hit (see Research Escalation). When escalating, message in this order:
   1. **Loop status** — which counter/cap was hit and how many rounds occurred.
   2. **The planner's current plan** — paste or closely summarize. The user cannot see subagent output, so this is their only way to understand what has been designed.
   3. **Blocking issues** — unresolved reviewer concerns or the pending research question.
6. Once the reviewer returns `APPROVED`, enter plan mode and present the final plan to the user for approval.

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

In that case, draft the plan directly in the main conversation and present it for approval.

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
- Orchestrator (main Claude) only summarizes each discussion round to the user — do not dump full transcripts into the conversation
- Follow `rules/orthogonality.md` for cross-platform and naming consistency
- **One user-facing confirmation per run** — the only user confirmation is the final plan approval in step 6. Never pause for user confirmation during intermediate revision rounds (steps 3–4): write draft files silently and inform the user with plain text only.

## Completion

After completing this skill:
1. Run: `echo "<<WORKFLOW_MARK_STEP_plan_complete>>"` (must be the ENTIRE Bash command — no pipes, no && chaining, no redirection)
2. Record the branching decision: consult `rules/branch.md` and `rules/worktree.md`, then run `echo "<<WORKFLOW_BRANCHING_DECIDED: <decision>>"`
3. Invoke `write-tests` via the Skill tool (or skip with `echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>"`).

