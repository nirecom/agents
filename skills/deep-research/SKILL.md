---
name: deep-research
description: Research external information (APIs, libraries, best practices, existing solutions) via web search before planning or implementation.
model: opus
effort: medium
---

Investigate external information related to the given task.

## Procedure

DR-1. **Delegate to web-researcher**:
   ```
   Agent({ subagent_type: "web-researcher", prompt: JSON.stringify({
     topic: TOPIC, context: CONTEXT,
     artifact_dir: PLANS_DIR
   }) })
   ```
   On `failed` status: surface summary to user and stop.

DR-2. Read the report from `artifact_path` (one read, at the end).
DR-3. **Present findings** — output format: `## Deep Research: PERFORMED|FAILED` (1 line) + artifact_path pointer (1 line) + ≤200 char summary. Do not re-emit the full report text in assistant output. The caller must not re-summarize or paraphrase these findings — DR-3 output is the complete user-facing surface.

## Rules

- Do not modify any project files
- Always include source URLs for traceability
- Prefer primary sources (official docs, RFCs) over blog posts
- When sources contradict each other, report both sides instead of choosing one

## Completion

After completing this skill:
1. Run: `node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --advance --step research --complete --next` (must be the ENTIRE Bash command — no `cd`, no pipes, no && chaining, no redirection)
2. Follow the returned `ACTION` / `NEXT_SKILL` / `NEXT_HINT` per CLAUDE.md.

Skip this skill when no external knowledge is needed (e.g., the task is purely internal to the codebase).

If research is genuinely not needed for this task:
1. Run: `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: {reason}>>"` (reason must be ≥3 non-space chars, not a placeholder like "none"/"skip", and contain no '>')
