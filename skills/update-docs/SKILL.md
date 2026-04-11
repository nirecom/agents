---
name: update-docs
description: Update all project documentation to reflect recent changes
model: sonnet
effort: low
---

Update all project documentation to reflect recent changes

## Project Detection

Determine the docs location based on the current project:

- **General projects** (dotfiles, etc.):
  - Docs directory: `docs/` within the project root
  - Target files: `README.md`, `architecture.md`, `todo.md`, `history.md`, `ops.md` (existing files only)

- **ai-specs projects** (langchain-stack, litellm-stack, open-webui-stack, portable-llm-server, llama-swap, judgeclaw):
  - Docs directory: `../ai-specs/projects/engineering/` (subdirectory per project: `langchain/`, `llama-swap/`, `judgeclaw/`, etc.)
  - If not found locally, clone from `git@github.com:nirecom/ai-specs.git`
  - Target: all `.md` files in the directory
  - Also update `README.md` in the source repo root
  - Source repos for change detection:
    - `../langchain-stack/` → `git@github.com:nirecom/langchain-stack.git`
    - `../open-webui-stack/` → `git@github.com:nirecom/open-webui-stack.git`
    - `../portable-llm-server/` → `git@github.com:nirecom/portable-llm-server.git`
    - `../llama-swap/` → `git@github.com:nirecom/llama-swap.git`
    - `../judgeclaw/` → `git@github.com:nirecom/judgeclaw.git`
  - **llama-swap additional**: when `config.yaml` changes, also update in-repo `model-annotations.yaml` and `optimization-history.md`

## Procedure

1. **Gather recent changes**:
   - Run `git diff` and `git diff --cached` to capture uncommitted and staged changes (current session's work, not yet in git log)
   - Run `git log --oneline -20` for committed history
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
6. **Propagate to parent docs**: For ai-specs projects, update parent-level counterparts
   (e.g. `langchain/todo.md` → `engineering/todo.md`). Skip for repo-local `docs/`.
7. **Commit separately**: If docs are in a separate repo (e.g., ai-specs), commit each repo independently

## Rules

- Follow the structure and content rules defined in `rules/docs-convention.md`
- Follow the gather → propose → confirm → apply cycle (never write without user confirmation)
- Compare git log against current docs to identify gaps

## Completion

After completing this skill, run:
`node "$DOTFILES_DIR/claude-global/hooks/mark-step.js" $CLAUDE_SESSION_ID docs complete`
