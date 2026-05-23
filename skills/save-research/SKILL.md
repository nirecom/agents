---
name: save-research
description: Save useful research findings to my-specs-repo research-results for future reference.
model: sonnet
effort: low
argument-hint: "<topic-slug>"
context: fork
---

Save research findings from the current conversation to a persistent research-results file.

## Procedure

1. **Identify findings**: Review the current conversation for research results worth preserving.
   If no research has been conducted yet, tell the user and stop.
2. **Determine filename**: Use the argument as the filename slug (kebab-case `.md`).
   If no argument was given, derive a slug from the research topic.
3. **Check for duplicates**: Read `../my-specs-repo/projects/engineering/research-results/`
   to see if a file on the same topic already exists.
   - If it exists, propose updating the existing file instead of creating a new one.
4. **Draft the document** in chat using this template:

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

5. **Wait for user approval** before writing the file.
6. **Write the file** to `../my-specs-repo/projects/engineering/research-results/<slug>.md`.
7. **Commit**: Run `git -C ../my-specs-repo add` and `git -C ../my-specs-repo commit` for the new file.
   This commit is to a separate repository (my-specs-repo). It is NOT the main project commit
   and must NOT trigger USER_VERIFIED or advance the calling workflow step.
8. **Return to caller**: After the commit, explicitly state which workflow step to resume
   (e.g., "save-research complete. Resuming Step 2a (research).") and do not mark
   any workflow phase as complete.

## Rules

- **Never set USER_VERIFIED after this skill** — this is an auxiliary tool called mid-workflow.
  Completing save-research does not constitute completion of the calling workflow step.
- Do not modify any files in the current project — output goes to my-specs-repo only
- Always include source URLs for traceability (no URLs = not worth saving)
- Content language: Japanese (my-specs-repo is a private repository)
- Follow the established format from existing files in research-results/
- Strip conversation-specific noise — save only the reusable knowledge
- Do not save trivial findings that are easily re-discoverable via a single web search
