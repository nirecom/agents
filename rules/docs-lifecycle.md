# Documentation Lifecycle

## When to Read Docs

At the start of a task that involves code changes, read the project's docs directory (existing files only):

| File | Responsibility | Format |
|------|---------------|--------|
| `architecture.md` | Architecture, design decisions | What/Why |
| `history.md` | Change history, incidents | Change History / Incident History tables, 7-char commit hashes |
| `todo.md` | Upcoming tasks | Checklist |
| `progress.md` | Phase progress | Phase table |
| `roadmap.md` | Roadmap | Milestone-based |
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
- Detection: determine from repository name or CLAUDE.md content
