---
name: complete-task
description: Complete a task and run post-processing
disable-model-invocation: true
argument-hint: "[task-id]"
---

Complete a task and run post-processing

## Arguments

$TASK_ID - Task identifier (e.g., 3E, 4, incident-xxx)

## Procedure

1. If a handoff document exists (`.context-private/handoff-phase{$TASK_ID}.md`), verify all completion criteria are met
2. Update the Implementation Phases table in the target repo's `CLAUDE.md` (if applicable)
3. Create `.context-private/completion-phase{$TASK_ID}.md` containing:
   - Completed work (files changed per commit)
   - Verification results
   - Corrections applied to handoff (if any)
   - Current system state (API format, config, etc.)
   - Notes and warnings for the next phase
4. Run `/update-docs` to update project documentation
5. Commit target repo changes
6. If docs are in a separate repo (e.g., ai-specs), commit that repo separately

## Rules

- Confirm with user before committing
- `.context-private/` is gitignored — Glob and Grep cannot see it.
  Use `ls` (Bash) to list files, and `Read` to read them directly by path.
- If completion criteria are not fully met, report the gaps and ask user how to proceed
