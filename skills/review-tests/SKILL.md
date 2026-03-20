---
name: review-tests
description: Review test coverage completeness using an Explore subagent
---

Review test case completeness against source code.

## Procedure

1. **Identify files**: Find the test file(s) and corresponding source file(s) being worked on.
   - Check `tests/` directory for recently modified test files
   - If ambiguous, ask the user which test and source files to review

2. **Launch Explore subagent**: Spawn an Explore subagent with the following instructions:
   - Read the test file(s) and corresponding source file(s)
   - Read `rules/test.md` for the Test Case Categories checklist
   - Evaluate test coverage against every category and sub-category in the checklist
   - For each category, report what IS covered, what is MISSING, and what is N/A (with reason)
   - For missing cases, suggest specific test descriptions

3. **Present results**: Show the subagent's findings to the user.
   - If gaps are found, propose specific test cases to add
   - Apply changes only after user approval

4. **Create review marker**: After review is complete (regardless of whether gaps were found),
   create the marker file so the commit hook knows review was done:
   ```bash
   git rev-parse --short HEAD | tr -d '\n' > "$(git rev-parse --git-dir)/.test-reviewed"
   ```

## Rules

- Always launch the subagent — do not skip the review even if tests look complete
- The subagent must read actual file contents, not just file names
- The checklist definition lives in `rules/test.md` — do not duplicate it here
- Create the marker file only after the review is genuinely complete
