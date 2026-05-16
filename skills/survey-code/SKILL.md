---
name: survey-code
description: Explore the codebase to understand existing patterns, constraints, and relevant files before planning.
model: sonnet
---

Investigate the codebase related to the given task.

## Procedure

0. **Claim extraction** (run before reading any code):
   Read `~/.workflow-plans/<session-id>-intent.md`. Extract up to 5 behavioral/factual
   claims from the Background/Motivation and Scope sections. Target claim patterns:
   "X is blocked", "X does Y", "X is broken", "X cannot Z". Aesthetic claims
   ("this code is ugly") and pure preference statements are out of scope.
   Works with Japanese and English intent.md content.
   If no verifiable claims are found, proceed to Step 1 with an empty claim list.

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
   "No verifiable behavioral/factual claims found in intent.md."
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

Skip this skill when the change target is already known (single file/function).

If research is genuinely not needed for this task (typo fix, docs-only change):
1. Run: `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>"` (reason must be ≥3 non-space chars, not a placeholder like "none"/"skip", and contain no '>')
2. Invoke `make-outline-plan` via the Skill tool.
