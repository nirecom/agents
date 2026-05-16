---
name: survey-code
description: Explore the codebase to understand existing patterns, constraints, and relevant files before planning.
model: sonnet
---

Investigate the codebase related to the given task.

## Procedure

0. **Claim extraction** (run before reading any code):
   Input precedence (read whichever exists first):
     (a) `~/.workflow-plans/<session-id>-intent.md` — preferred (post-clarify-intent calls)
     (b) `~/.workflow-plans/<session-id>-context.md` — fallback (pre-clarify-intent calls
         from workflow-init; use "User initial prompt" and "Issue body" sections)
   If neither exists: proceed to Step 1 with an empty claim list.
   Extract up to 5 behavioral/factual claims from Background/Motivation and Scope.
   Target: "X is blocked", "X does Y", "X is broken", "X cannot Z". Exclude aesthetic
   claims and pure preferences. Works with Japanese and English content.

1. Identify candidate files and areas using Glob and Grep.
2. Read relevant source files, configs, tests, and docs.
3. For each claim extracted in Step 0, verify it against the current codebase:
   - `verdict: holds` — evidence in code confirms the claim
   - `verdict: contradicted` — evidence in code contradicts the claim
   - `verdict: indeterminate` — insufficient evidence to confirm or deny
4. Summarize: existing patterns, architectural constraints, relevant files (with line numbers), and anything that affects implementation.
5. Write findings to `~/.workflow-plans/<session-id>-survey-code.md`. The file must
   include a `## Verified Claims` section:
   ```
   ## Verified Claims
   - claim: <text from intent.md>
     verdict: holds | contradicted | indeterminate
     evidence: <file:line or "no matching code found">
   ```
   If no claims were extracted in Step 0, write the section with the note
   "No verifiable behavioral/factual claims found in intent.md or context.md."
6. Present findings for user review before proceeding to plan.

## Rules

- Read-only — do not modify any files
- Use Explore subagents for broad searches when needed
- Follow `rules/orthogonality.md` — check cross-platform counterparts
- Do NOT emit the research-complete sentinel — `make-outline-plan` Step 0 aggregates
  both survey-code and survey-history before emitting it.

## Completion

After completing this skill:
1. Invoke `make-outline-plan` via the Skill tool.
   Note: when invoked as a parallel Agent subagent by workflow-init, skip this step —
   Do NOT invoke make-outline-plan. workflow-init orchestrates the next stage.

Skip this skill when the change target is already known (single file/function).

If research is genuinely not needed for this task (typo fix, docs-only change):
1. Run: `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>"` (reason must be ≥3 non-space chars, not a placeholder like "none"/"skip", and contain no '>')
2. Invoke `make-outline-plan` via the Skill tool.
