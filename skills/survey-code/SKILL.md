---
name: survey-code
description: Explore the codebase to understand existing patterns, constraints, and relevant files before planning.
effort: medium
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
