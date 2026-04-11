---
name: deep-research
description: Research external information (APIs, libraries, best practices, existing solutions) via web search before planning or implementation.
model: opus
effort: medium
---

Investigate external information related to the given task.

## Procedure

1. Formulate search queries covering the topic from multiple angles.
2. Search the web and fetch relevant pages.
3. Cross-validate findings across multiple sources.
4. Summarize: key findings, source credibility, and recommendations with source URLs.
5. Present findings for user review.

## Rules

- Do not modify any project files
- Always include source URLs for traceability
- Prefer primary sources (official docs, RFCs) over blog posts
- When sources contradict each other, report both sides instead of choosing one

## Completion

After completing this skill, run:
`node "$DOTFILES_DIR/claude-global/hooks/mark-step.js" $CLAUDE_SESSION_ID research complete`
