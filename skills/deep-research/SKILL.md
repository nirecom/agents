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
DR-3. **Present findings** — output format: `## Deep Research: PERFORMED|FAILED` (1 line) + artifact_path pointer (1 line) + ≤200 char summary. Do not re-emit the full report text in assistant output.

## Rules

- Do not modify any project files
- Always include source URLs for traceability
- Prefer primary sources (official docs, RFCs) over blog posts
- When sources contradict each other, report both sides instead of choosing one

## Completion

After completing this skill:
1. Run: `echo "<<WORKFLOW_MARK_STEP_research_complete>>"` (must be the ENTIRE Bash command — no pipes, no && chaining, no redirection)

Skip this skill when no external knowledge is needed (e.g., the task is purely internal to the codebase).

If research is genuinely not needed for this task:
1. Run: `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>"` (reason must be ≥3 non-space chars, not a placeholder like "none"/"skip", and contain no '>')
