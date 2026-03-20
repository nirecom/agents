# Documentation Lifecycle

## When to Read Docs

At the start of a task that involves code changes, read the project's docs directory (existing files only):

| File | Responsibility | Format |
|------|---------------|--------|
| `architecture.md` | Architecture, design decisions, future phase specs | What/Why |
| `todo.md` | Current work pointer, active tasks, phase status | Status Summary + Checklist |
| `history.md` | Completed phases, incidents, change archive | Phase Detail sections, append-only |
| `ops.md` | Setup procedures, operations | How |

Skip reading docs for investigation-only or Q&A conversations.

## When to Update Docs

At task completion, propose updates to the relevant docs files based on changes made.

## Update Rules

- Always follow the gather → propose → confirm → apply cycle (never write without user confirmation)
- Compare git log against current docs to identify gaps
- Match the existing language style of each file
- Do not use GitHub links (use commit hashes only)

## Path Resolution

- **General projects:** `docs/` directory
- **LangChain projects** (langchain-stack, open-webui-stack, etc.): all `.md` files under `../ai-specs/projects/engineering/langchain/`
- **ai-specs managed projects** (ai-video, nemoclaw, llama-swap): `projects/engineering/{project}/`
- Detection: determine from repository name or CLAUDE.md content
