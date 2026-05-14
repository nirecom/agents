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

1a. **Auto-detect closes_issues**: Before the interview, scan the user's initial message
    for `#<digits>` tokens (GitHub issue references) and the pre-fill file (step 1b):
    When a pre-fill file sets the issue number, that value satisfies this step automatically —
    do not ask the user for the issue number a second time.
    - Exactly one `#N` found and context is unambiguous (e.g., "implement #261", "fix #42"):
      record as `closes_issues: [N]` without asking.
    - Multiple `#N` found or ambiguous: ask one `AskUserQuestion` during the step 3
      interview to identify the single issue this session closes. Counts toward the
      5-round budget but is treated as required.
    - Zero `#N` found or task is clearly issue-free: set `closes_issues: []`; do not ask.
    **One issue per session** is the basic premise. Never auto-add all detected numbers.

1b. **Detect pre-fill context**: Check whether
    `~/.workflow-plans/drafts/<session-id>-issue-prefill.md` exists (written by `/workflow-init`
    on Path B). If present:
    - Read it.
    - Treat its body as the seed for Background / Motivation / Scope.
    - First AskUserQuestion is confirmation-style:
      "The issue body says: <one-line summary>. How do you want to proceed?
       (Recommended: Approve framing — continue | Revise — what changes? | Start over — discard pre-fill)"
    - On Approve / Revise: skip the background question in subsequent rounds. 5-round cap still applies.
    - On Start over: remove the pre-fill file (`Remove-Item` / `rm`) and proceed with the standard interview.
    If absent, proceed normally to step 2.

2. Check `CONFIRM_OUTLINE` flag:
   Run via Bash: `bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off CONFIRM_OUTLINE on && echo OFF || echo ON'`
   - stdout `OFF`: the outline stage's `AskUserQuestion` (approach selection) will be skipped,
     so delivery plan direction must be captured here. Include a question about delivery plan
     direction (single PR vs. phased, execution order) in the step 3 interview, treating it as
     a required question even if the 5-round limit would otherwise exclude it.
   - stdout `ON`: proceed normally — delivery plan direction is the outline stage's responsibility.

3. Conduct a decision-tree interview using `AskUserQuestion`. Rules:
   - **1 question per invocation** — never batch multiple questions into one call.
   - Each option MUST include exactly one marked **(recommended)** option so the user can
     ratify the recommendation rather than having to invent an answer from scratch.
   - Walk in **dependency order** — only branch into sub-questions after a parent decision is
     confirmed.
   - **Maximum 5 rounds.** If understanding is still incomplete after 5 rounds, document the
     remaining ambiguities as constraints in the output and proceed.
   - If a question can be answered by exploring the codebase (e.g., "does X already exist?"),
     explore via Read/Grep/Glob instead of asking.

4. After the interview (or at the 5-round cap), write the agreed requirements to:
   ```
   ~/.workflow-plans/<session-id>-intent.md
   ```
   Use the Write tool directly — do NOT run mkdir first (Write creates parent directories automatically).
   Use the schema below. The `<session-id>` must be the current Claude session ID.
   Read `CLAUDE_SESSION_ID` from `$CLAUDE_ENV_FILE` if available; otherwise use a
   timestamp (`YYYYMMDD-HHMMSS`) as fallback.

5. Apply the confirm-plan protocol (`skills/_shared/confirm-plan.md`)
   using `CONFIRM_INTENT` as the flag and `<session-id>-intent.md` as the artifact.
   - **Revise** (skill-specific): ask the user what to change, update intent.md with the
     Write tool (re-run the interview loop if scope changes are significant), then loop
     back to the protocol's Step 1.

6. Proceed to Plan step 2 — starting with Research (2a: `/survey-code` or `/deep-research`,
   unless not needed) then `/make-outline-plan`.

## Output Schema

Write one file (per `rules/language.md`):

### `<session-id>-intent.md`

- **Title**: "Agreed Requirements" + `<session-id>`
- **Background / Motivation**: 1-2 paragraphs on why this task is needed
- **Scope**: what is included / what is excluded (non-goals)
- **Constraints**: list of constraints
- **Interview Log** (optional): each Q&A round recorded as "Q: ... A: ..."
- **closes_issues**: GitHub issue numbers this session is expected to close.
  Always present. Serialized as a markdown list of integers (no `#` prefix).
  Write an empty list when no issues are being closed.

  Non-empty example:
  ```
  ## closes_issues
  - 261
  ```

  Empty example:
  ```
  ## closes_issues
  (empty)
  ```

## Completion

After the interview AND the confirm-plan protocol have returned, reconcile with GitHub
BEFORE emitting the completion sentinel.

**Issue reconciliation:**

1. Read the just-written intent.md to extract `closes_issues`.

2. If `closes_issues` lists exactly one issue `N`:
   - Check current labels: `gh issue view <N> --json labels --jq '.labels[].name'`
   - If `intent:clarified` is NOT already present:
     `gh issue edit <N> --add-label "intent:clarified"`
   - On `gh` failure: warn the user with a `[clarify-intent]` prefix, do NOT block.
     Record `intent:clarified-label-failed: <reason>` under `## Constraints` in intent.md via Edit.

3. If `closes_issues` is empty (Path C — no issue at session start):
   - Auto-create the tracking issue (no AskUserQuestion — intent.md mandates auto):
     ```
     gh issue create \
       --title "<first ~50 chars of intent's Title/first heading>" \
       --body  "<HEREDOC: Background/Motivation + Scope + Constraints + auto-created footer>"
       --label "intent:clarified"
     ```
     Body composition:
     ```
     ## Background / Motivation
     <copy verbatim from intent.md>

     ## Scope
     <copy verbatim from intent.md>

     ## Constraints
     <copy verbatim from intent.md>

     (Auto-created from clarify-intent — session <session-id>)
     ```
   - On success: extract the issue number from the URL `gh issue create` prints (trailing integer).
     Update intent.md's `## closes_issues` via Edit: replace `(empty)` with `- <N>`.
   - On failure (no auth / no network / missing label / repo no-issues policy):
     warn with `[clarify-intent]` prefix, leave `closes_issues` as `(empty)`, continue.

4. If `closes_issues` has multiple issues: abort with error citing `rules/github-issues.md`
   (one issue per session is the standing convention).

**Completion sentinels and hand-off:**

1. Run: `echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"` (hook returns next-step hint; Tier 2 early gate disengages)
2. Create a TodoWrite checklist for the remaining workflow steps
   (mark `workflow_init` + `clarify_intent` as completed):
   - Research (`/survey-code` or `/deep-research`, or skip with NOT_NEEDED)
   - Plan (`/make-outline-plan` → `/make-detail-plan`, or skip with NOT_NEEDED)
   - Branching decision (consult `rules/branch.md` + `rules/worktree.md`)
   - Write tests (`/write-tests`, or skip with NOT_NEEDED)
   - Code (present diff in chat before Edit)
   - Run tests + Security review + Codex review in parallel
   - Docs (`/update-docs`)
   - User verification (`echo "<<WORKFLOW_USER_VERIFIED>>"`)
   - Commit + Cleanup (`/commit-push`, then `/worktree-end` per branching decision)
3. Invoke `survey-code` or `deep-research` via the Skill tool if needed
   (or skip with `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>"`), then invoke `make-outline-plan`.
