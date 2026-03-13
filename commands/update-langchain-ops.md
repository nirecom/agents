Update `ops.md` to reflect infrastructure changes in the LangChain LLM-as-a-Judge project

## Target files

- `ops.md` is searched in this order:
  - Local directory `../ai-specs/projects/engineering/langchain/`
  - git repo `git@github.com:nirecom/ai-specs.git` (path: `projects/engineering/langchain/ops.md`)

- Source repos (for detecting infrastructure changes):
  - langchain-stack: `../langchain-stack/` → `git@github.com:nirecom/langchain-stack.git`
  - litellm-stack: `../litellm-stack/` → `git@github.com:nirecom/litellm-stack.git`
  - open-webui-stack: `../open-webui-stack/` → `git@github.com:nirecom/open-webui-stack.git`
  - portable-llm-server: `../portable-llm-server/` → `git@github.com:nirecom/portable-llm-server.git`

## Procedure

1. **Gather recent changes**: For each source repo, run `git log --oneline -20` and check for infrastructure-related commits (docker-compose, .env, ports, services, config)
2. **Read current ops doc**: Read `ops.md`
3. **Identify updates**: Compare commits against the ops document:
   - Port allocation changes
   - New services or service configuration changes
   - Network or access URL changes
   - New environment variables
   - New gotchas discovered during development
   - Setup procedure changes
   - Directory structure changes
4. **Propose updates**: Present changes to the user:
   - Which sections need updating and why
   - New Key Gotchas entries if applicable
5. **Apply after confirmation**: Edit the file only after user approval

## Rules

- Language: Japanese (the document is written in Japanese)
- Do NOT duplicate architecture or design decisions — reference `architecture.md` instead
- Do NOT include phase progress — reference `progress.md` instead
- Keep setup procedures actionable (include actual commands)
- New environment variables must document: variable name, default, purpose, and which phase introduced them
