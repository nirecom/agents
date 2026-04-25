---
name: survey-code
description: Explore the codebase to understand existing patterns, constraints, and relevant files before planning.
---

Investigate the codebase related to the given task. Read-only — do not modify any files.

## Steps

1. Identify candidate files and areas using search tools and directory listings.
2. Read relevant source files, configs, tests, and docs.
3. Check cross-platform counterparts (per `rules/orthogonality.md`):
   when a file under `install/win/` is relevant, also check `install/linux/`, and vice versa.
4. Summarize findings: existing patterns, architectural constraints, relevant files
   (with line numbers), and anything that affects implementation.
5. Present findings before any planning or implementation begins.

## What to look for

- Existing functions or utilities that can be reused (avoid proposing new code when suitable implementations already exist)
- Naming conventions and file organization patterns
- Test patterns and coverage for the affected area
- Any cross-platform or cross-tool consistency requirements
