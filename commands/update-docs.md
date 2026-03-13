Update all project documentation to reflect recent changes

## Project Detection

Determine the docs location based on the current project:

- **LangChain projects** (langchain-stack, litellm-stack, open-webui-stack, portable-llm-server):
  - Docs directory: `../ai-specs/projects/engineering/langchain/`
  - If not found locally, clone from `git@github.com:nirecom/ai-specs.git`
  - Target: all `.md` files in the directory
  - Source repos for change detection:
    - `../langchain-stack/` → `git@github.com:nirecom/langchain-stack.git`
    - `../litellm-stack/` → `git@github.com:nirecom/litellm-stack.git`
    - `../open-webui-stack/` → `git@github.com:nirecom/open-webui-stack.git`
    - `../portable-llm-server/` → `git@github.com:nirecom/portable-llm-server.git`

- **General projects** (dotfiles, etc.):
  - Docs directory: `docs/` within the project root
  - Target files: `architecture.md`, `history.md`, `todo.md`, `progress.md`, `roadmap.md` (existing files only)
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

- Follow the format conventions defined in `rules/docs-lifecycle.md`
- Match the existing language style of each file (some files are Japanese, some English)
- Do not use GitHub links (use commit hashes only, 7 characters)
- For history.md: group related commits by phase, use table format
- For architecture.md: document What/Why, not How (How belongs in ops.md)
- For progress.md: use checkbox format (`- [x]` / `- [ ]`), keep summary table in sync
- For ops.md: keep procedures actionable with actual commands
- Do not duplicate content across documents — cross-reference instead
