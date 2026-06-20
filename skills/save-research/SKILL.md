---
name: save-research
description: Save useful research findings to ai-specs research-results for future reference.
model: sonnet
effort: low
argument-hint: "<topic-slug>"
context: fork
---

Save research findings from the current conversation to a persistent research-results file.

## Procedure

SR-1. **Identify findings**: Review the current conversation for research results worth preserving.
   If no research has been conducted yet, tell the user and stop.
SR-2. **Determine filename**: Use the argument as the filename slug (kebab-case `.md`).
   If no argument was given, derive a slug from the research topic.
SR-3. **Check for duplicates**: Read `../ai-specs/projects/engineering/research-results/`
   to see if a file on the same topic already exists.
   - If it exists, propose updating the existing file instead of creating a new one.
SR-4. **Draft the document** in chat using this template:

   ```
   # <Title>

   Date: <YYYY-MM-DD>
   Motivation: <why this research was needed — the question or decision it informed>

   ## Background

   <context that motivated the investigation>

   ## Key Findings

   ### 1. <Finding>
   <summary>

   **Sources:**
   - <URLs>

   ### 2. <Finding>
   ...

   ## Applied Analysis

   <how findings apply to the project — tables, trade-offs, recommendations>

   ## Conclusion

   <actionable conclusion with numbered rationale>
   ```

SR-5. **Wait for user approval** before writing the file.
SR-6. **Write the file** to `../ai-specs/projects/engineering/research-results/<slug>.md`.
SR-7. **Commit**: Run `git -C ../ai-specs add` and `git -C ../ai-specs commit` for the new file.
   This commit is to a separate repository (ai-specs). It is NOT the main project commit
   and must NOT trigger USER_VERIFIED or advance the calling workflow step.
SR-8. **Return to caller**: After the commit, explicitly state which workflow step to resume
   (e.g., "save-research complete. Resuming Step 2a (research).") and do not mark
   any workflow phase as complete.

## Rules

- **Never set USER_VERIFIED after this skill** — this is an auxiliary tool called mid-workflow.
  Completing save-research does not constitute completion of the calling workflow step.
- Do not modify any files in the current project — output goes to ai-specs only
- Always include source URLs for traceability (no URLs = not worth saving)
- Content language: Japanese (ai-specs is a private repository)
- Follow the established format from existing files in research-results/
- Strip conversation-specific noise — save only the reusable knowledge
- Do not save trivial findings that are easily re-discoverable via a single web search
