---
name: deep-research
description: Research external information via web search before planning or implementation.
agent: coding
tools:
  - fetch
---

Research external information related to the given task.

## Steps

1. Formulate search queries covering the topic from multiple angles.
2. Fetch relevant pages from official documentation and primary sources.
3. Cross-validate findings across multiple sources.
4. Summarize: key findings, source credibility, and recommendations with source URLs.
5. Present findings — do not modify any project files.

## Rules

- Prefer primary sources (official docs, RFCs, specs) over blog posts.
- When sources contradict each other, report both sides instead of choosing one.
- Always include source URLs for traceability.
- Report uncertainty clearly — do not present guesses as facts.
