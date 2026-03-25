---
name: update-instruction
description: Update infrastructure.md to reflect infrastructure changes across all stacks and hosts
---

Update `infrastructure.md` to reflect infrastructure changes across all stacks and hosts

## Target files

- `infrastructure.md` is searched in this order:
  - Local directory `../ai-specs/projects/engineering/`
  - git repo `git@github.com:nirecom/ai-specs.git` (path: `projects/engineering/infrastructure.md`)

- Source repos (for detecting changes):
  - langchain-stack: `../langchain-stack/` → `git@github.com:nirecom/langchain-stack.git`
  - open-webui-stack: `../open-webui-stack/` → `git@github.com:nirecom/open-webui-stack.git`
  - portable-llm-server: `../portable-llm-server/` → `git@github.com:nirecom/portable-llm-server.git`

- Related design docs (already-documented changes to reflect):
  - `langchain/architecture.md` (subdirectory of infrastructure.md's directory)
  - `langchain/ops.md` (subdirectory of infrastructure.md's directory)

## Procedure

1. **Gather recent changes**: For each source repo, run `git log --oneline -20`. Also check `langchain/architecture.md` and `langchain/ops.md` for recently documented changes not yet in infrastructure.md
2. **Read current infrastructure.md**: Understand what is already documented
3. **Identify gaps**: Compare against infrastructure.md. Look for:
   - Host service changes (Windows host services, Mac services, QNAP docker-stacks)
   - Stack additions or removals
   - Port allocation changes
   - Connection topology changes
   - Docker network changes
   - Hardware or network equipment changes
4. **Propose updates**: Present a summary of proposed changes to the user:
   - Which sections need updating and why
   - Specific additions or modifications
5. **Apply after confirmation**: Edit the file only after user approval

## Rules

- Language: Japanese/English mixed (match existing style per section)
- infrastructure.md is pasted into a Claude.ai web project — keep it concise (~200 lines)
- Show **structure only** — do not add operational procedures (those belong in `langchain/ops.md`)
- Do not duplicate design details — reference `langchain/architecture.md` instead
- Do not add phase progress — reference `langchain/progress.md` instead
- The "Coding Guidelines" and "Agent Context File Conventions" sections are maintained separately; do not modify unless explicitly requested
