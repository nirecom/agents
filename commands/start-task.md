Start a task (phase implementation, incident response, or improvement)

## Arguments

$TASK_ID - Task identifier (e.g., 3E, 4, incident-xxx)

## Project Detection

Determine the docs location based on the current project:

- **LangChain projects** (langchain-stack, litellm-stack, open-webui-stack, portable-llm-server):
  - Docs: `../ai-specs/projects/engineering/langchain/`
- **General projects**: Docs: `docs/` within the project root

## Procedure

1. Read project docs (follow path resolution from project detection above):
   - `architecture.md`, `progress.md` (and other existing docs)
2. Read the target repo's `CLAUDE.md`
3. Read `.context-private/handoff-phase{$TASK_ID}.md` (if exists)
4. Read `.context-private/completion-phase{prev}.md` (if exists — determine prev from progress.md)
5. Read `ops.md` (for incident/infrastructure tasks)
6. Cross-check handoff against higher-priority documents:
   - **Priority 1**: Project docs (`architecture.md`, `progress.md`, `CLAUDE.md`)
   - **Priority 2**: Previous completion report
   - **Priority 3**: Current handoff
7. If conflicts found, present them to the user before proceeding
8. Present a work plan to the user and wait for approval before starting implementation

## Rules

- If no handoff document exists, ask the user for task scope
- Never start implementation without presenting the plan first
- `.context-private/` is gitignored — Glob and Grep cannot see it.
  Use `ls` (Bash) to list files, and `Read` to read them directly by path.
