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

2. **Determine the planner subagent's model**:
   - Read `skills/judge-task-complexity/SKILL.md` to load the signal table.
   - Evaluate all signals against the full task context plus the contents of intent/outline files (if they exist). Do not short-circuit on the first match.
   - Apply the routing rule: 1+ signals → `opus`; 0 signals → `sonnet`; ambiguous → `opus`.
   - Emit in Claude text output (NOT Bash echo):
     > Model selected: **[opus|sonnet]** (signals: [comma-separated triggered signal IDs, or "none"])

3. Delegate initial drafting to the **planner** subagent (Agent tool, `subagent_type: detail-planner`, `model: <model from step 2>`).
   Pass the full task context **plus** the contents of the intent/approach files above.

4. **Review the draft with codex first, fall back to Claude if unavailable.**
   For each review round:
   a. Write the planner's draft using the Write tool to:
      `~/.claude/plans/drafts/<session-id>-detail-draft.md`

      Defensive fallback: if `~/.claude/plans/drafts/` does not yet exist, run
      `mkdir -p ~/.claude/plans/drafts` via Bash first (idempotent).
   b. **Build the review context file** (once per skill invocation; reuse across revision rounds).
      On the first review round only, determine which prior-stage files exist:
      - `~/.claude/plans/<session-id>-intent.md`
      - `~/.claude/plans/<session-id>-outline.md`

      Write `~/.claude/plans/drafts/<session-id>-context.md` with whichever sections apply
      (English headers mandatory, source comments mandatory):
      ```
      <!-- Source: ~/.claude/plans/<session-id>-intent.md -->
      ## Section 1: Intent (User Requirements)

      <verbatim contents of <session-id>-intent.md>

      ---

      <!-- Source: ~/.claude/plans/<session-id>-outline.md -->
      ## Section 2: Outline (Design Proposal)

      <verbatim contents of <session-id>-outline.md>
      ```
      Fallback rules:
      - If only the intent file exists: Section 1 only (no separator, no Section 2).
      - If only the outline file exists: Section 2 only (no separator, no Section 1).
      - If neither exists: skip context file; call review-plan-codex without `--context`.

      On revision rounds 2+, reuse the context file from round 1 — do not regenerate.
   c. Run via Bash: `review-plan-codex --input ~/.claude/plans/drafts/<session-id>-detail-draft.md --format detail-plan [--context ~/.claude/plans/drafts/<session-id>-context.md]`
      (omit `--context` when no context file was created in step b)
   d. Parse the first line of stdout:
      - `## Codex Plan Review: PERFORMED` → read inside `<!-- begin-codex-output -->` fences.
        Extract the first non-blank line as the verdict token.
        - `APPROVED` → loop done, proceed to step 6.
        - `NEEDS_REVISION` → extract numbered concerns (lines starting `1.`, `2.`, …) and treat as reviewer concerns. If no concerns parse, treat as malformed (below).
        - Anything else → **format malformed**.
      - `## Codex Plan Review: SKIPPED — …` or `FAILED — …` → **codex unavailable**.
      - **Format malformed**: append `<ISO-timestamp> round=<N> codex output malformed (could not parse verdict)` to `~/.claude/plans/drafts/<session-id>-detail-debug.log` via Bash `printf '%s\n' "..." >> <path>` and silently launch `detail-reviewer` subagent. Do NOT emit to chat.
      - **Codex unavailable**: append `<ISO-timestamp> round=<N> codex unavailable (<reason from status line>)` to `~/.claude/plans/drafts/<session-id>-detail-debug.log` and silently launch `detail-reviewer` subagent. Do NOT emit to chat.
   e. Whether from codex or Claude reviewer: if result is `NEEDS_REVISION`, send concerns back to planner for revision (using the same model from step 2), then repeat from step 4a. Each round consumes `revision_rounds`.

5. **Escalate to the user** if the loop reaches **2 revision rounds** without approval, or a research/malformed-retry cap is hit (see Research Escalation). When escalating, message in this order:
   1. **Loop status** — which counter/cap was hit and how many rounds occurred.
   2. **The planner's current plan** — paste or closely summarize. The user cannot see subagent output, so this is their only way to understand what has been designed.
   3. **Blocking issues** — unresolved reviewer concerns or the pending research question.

6. Once the reviewer returns `APPROVED`, write the final plan to
   `~/.claude/plans/<session-id>-detail.md` (not draft). Present it to the user as a
   clickable link using the **resolved absolute path** (do not use `~` in the link
   target — tilde is not expanded in markdown rendering, so the link won't open).
   Do not paste the full content in chat.
   - POSIX: `[<session-id>-detail.md](/home/<user>/.claude/plans/<session-id>-detail.md)`
   - Windows: `[<session-id>-detail.md](C:/Users/<user>/.claude/plans/<session-id>-detail.md)`

   After writing and presenting the link, check via Bash:
     `bash -c 'get-config-var --is-off CONFIRM_DETAIL on && echo OFF || echo ON'`
   - stdout `OFF`: print a one-paragraph summary and emit `<<WORKFLOW_MARK_STEP_plan_complete>>` directly. Skip plan mode.
   - stdout `ON`: enter plan mode for user approval (existing behavior).

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
- Orchestrator chat output during the discussion loop is restricted to:
  (a) one status line per round (`Round N: APPROVED` or `Round N: NEEDS_REVISION (proceeding)`)
  (b) the final clickable link to <session-id>-detail.md
  Diagnostics go to <session-id>-detail-debug.log only.
- Follow `rules/orthogonality.md` for cross-platform and naming consistency
- **One user-facing confirmation per run** — the only user confirmation is the final plan approval in step 6. Never pause for user confirmation during intermediate revision rounds (steps 3–4): write draft files silently and inform the user with plain text only.

## Completion

After completing this skill:
1. Run: `echo "<<WORKFLOW_MARK_STEP_plan_complete>>"` (must be the ENTIRE Bash command — no pipes, no && chaining, no redirection)
2. Record the branching decision: consult `rules/branch.md` and `rules/worktree.md`, then run `echo "<<WORKFLOW_BRANCHING_COMPLETE: branch: <name>|worktree: <path>|main>>"`
3. Invoke `write-tests` via the Skill tool (or skip with `echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>"`).

