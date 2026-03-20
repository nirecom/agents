---
name: update-docs
description: Update all project documentation to reflect recent changes
---

Update all project documentation to reflect recent changes

## Project Detection

Determine the docs location based on the current project:

- **LangChain projects** (langchain-stack, litellm-stack, open-webui-stack, portable-llm-server):
  - Docs directory: `../ai-specs/projects/engineering/langchain/`
  - If not found locally, clone from `git@github.com:nirecom/ai-specs.git`
  - Target: all `.md` files in the directory
  - Source repos for change detection:
    - `../langchain-stack/` → `git@github.com:nirecom/langchain-stack.git`
    - `../open-webui-stack/` → `git@github.com:nirecom/open-webui-stack.git`
    - `../portable-llm-server/` → `git@github.com:nirecom/portable-llm-server.git`

- **General projects** (dotfiles, etc.):
  - Docs directory: `docs/` within the project root
  - Target files: `architecture.md`, `todo.md`, `history.md`, `ops.md` (existing files only)
  - Also update `README.md` if file tree or installation procedure changed

## Procedure

1. **Gather recent changes**: Run `git log --oneline -20` for the current repo (and source repos for LangChain projects)
2. **Read current docs**: Read all target docs files
3. **Identify gaps**: Compare git log against each document's content. Look for:
   - Unrecorded commits or phases
   - Architecture/design changes not yet documented
   - New incidents or bug fixes
   - Infrastructure or operational changes
   - Progress updates
4. **Propose updates**: For each file that needs updating, present:
   - Which sections need changes and why
   - Specific additions or modifications
5. **Apply after confirmation**: Edit files only after user approval
6. **Commit separately**: If docs are in a separate repo (e.g., ai-specs), commit each repo independently

## Rules

- Follow the structure and content rules defined in `rules/docs-convention.md`
- Follow the gather → propose → confirm → apply cycle (never write without user confirmation)
- Compare git log against current docs to identify gaps
