Complete a LangChain task and run post-processing

## Arguments

$TASK_ID - Task identifier (e.g., 3E, 4, incident-xxx)

## Procedure

1. If a handoff document exists (`.context-private/handoff-phase{$TASK_ID}.md`), verify all completion criteria are met
2. Update the Implementation Phases table in the satellite repo's `CLAUDE.md`
3. Create `.context-private/completion-phase{$TASK_ID}.md` containing:
   - Completed work (files changed per commit)
   - Verification results
   - Corrections applied to handoff (if any)
   - Current system state (API format, config, etc.)
   - Notes and warnings for the next phase
4. Run `/update-langchain-docs` to update PJ global docs (progress → design → ops)
5. Commit satellite repo changes
6. Commit ai-specs changes separately

## Rules

- Confirm with user before committing
- ai-specs is PRIVATE — never reference its content in commits to public repos
- `.context-private/` is gitignored — Glob and Grep cannot see it.
  Use `ls` (Bash) to list files, and `Read` to read them directly by path.
- If completion criteria are not fully met, report the gaps and ask user how to proceed
