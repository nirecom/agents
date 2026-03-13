Update `architecture.md` to reflect recent design changes in the LangChain LLM-as-a-Judge project

## Target files

- `architecture.md` is searched in this order:
  - Local directory `../ai-specs/projects/engineering/langchain/`
  - git repo `git@github.com:nirecom/ai-specs.git` (path: `projects/engineering/langchain/architecture.md`)

- Source repos (for detecting changes):
  - langchain-stack: `../langchain-stack/` → `git@github.com:nirecom/langchain-stack.git`
  - litellm-stack: `../litellm-stack/` → `git@github.com:nirecom/litellm-stack.git`
  - open-webui-stack: `../open-webui-stack/` → `git@github.com:nirecom/open-webui-stack.git`
  - portable-llm-server: `../portable-llm-server/` → `git@github.com:nirecom/portable-llm-server.git`

## Procedure

1. **Gather recent changes**: For each source repo, run `git log --oneline -20` to identify recent commits
2. **Read current design**: Read `architecture.md` to understand what is already documented
3. **Identify gaps**: Compare git log entries against the design document. Look for:
   - New or changed architecture decisions
   - New or modified modules, config files, or dependencies
   - Model changes (reasoner, judge, direct)
   - New Stack configurations or docker-compose changes
   - Risk/mitigation updates
4. **Propose updates**: Present a summary of proposed changes to the user:
   - Which sections need updating and why
   - Specific additions or modifications
5. **Apply after confirmation**: Edit the file only after user approval

## Rules

- Language: Japanese (the document is written in Japanese)
- Keep the document concise (~500 lines target)
- Do NOT add phase progress details — those belong in `progress.md`
- Do NOT add infrastructure setup procedures — those belong in `ops.md`
- Config files that embody design decisions may stay inline
- Follow the existing document structure (sections 1-13)
