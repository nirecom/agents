---
name: save-research
description: Save useful research findings to ai-specs research-results for future reference.
model: sonnet
effort: low
argument-hint: "<topic-slug>"
---

Save research findings from the current conversation to a persistent research-results file.

## Procedure

1. **Identify findings**: Review the current conversation for research results worth preserving.
   If no research has been conducted yet, tell the user and stop.
2. **Determine filename**: Use the argument as the filename slug (kebab-case `.md`).
   If no argument was given, derive a slug from the research topic.
3. **Check for duplicates**: Read `../ai-specs/projects/engineering/research-results/`
   to see if a file on the same topic already exists.
   - If it exists, propose updating the existing file instead of creating a new one.
4. **Draft the document** in chat using this template:

   ```
   # <Title>

   調査日: <YYYY-MM-DD>
   調査動機: <why this research was needed — the question or decision it informed>

   ## 背景

   <context that motivated the investigation>

   ## 主要な研究結果

   ### 1. <Finding>
   <summary>

   **Sources:**
   - <URLs>

   ### 2. <Finding>
   ...

   ## 適用分析

   <how findings apply to the project — tables, trade-offs, recommendations>

   ## 結論

   <actionable conclusion with numbered rationale>
   ```

5. **Wait for user approval** before writing the file.
6. **Write the file** to `../ai-specs/projects/engineering/research-results/<slug>.md`.
7. **Commit**: Run `git -C ../ai-specs add` and `git -C ../ai-specs commit` for the new file.

## Rules

- Do not modify any files in the current project — output goes to ai-specs only
- Always include source URLs for traceability (no URLs = not worth saving)
- Content language: Japanese (ai-specs is a private repository)
- Follow the established format from existing files in research-results/
- Strip conversation-specific noise — save only the reusable knowledge
- Do not save trivial findings that are easily re-discoverable via a single web search
