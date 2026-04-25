---
name: survey-code
description: Explore the codebase to understand existing patterns, constraints, and relevant files before planning.
model: sonnet
effort: low
---

Investigate the codebase related to the given task.

## Procedure

1. Identify candidate files and areas using Glob and Grep.
2. Read relevant source files, configs, tests, and docs.
3. Summarize: existing patterns, architectural constraints, relevant files (with line numbers), and anything that affects implementation.
4. Present findings for user review before proceeding to plan.

## Rules

- Read-only — do not modify any files
- Use Explore subagents for broad searches when needed
- Follow `rules/orthogonality.md` — check cross-platform counterparts

## Completion

After completing this skill, run:
`echo "<<WORKFLOW_MARK_STEP_research_complete>>"`
(This echo must be the ENTIRE Bash command — no pipes, no && chaining, no redirection.)

If research is genuinely not needed for this task, run instead:
`echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>"`
(reason must be ≥3 non-space chars, not a placeholder like "none"/"skip", and contain no '>'.)
