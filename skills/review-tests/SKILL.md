---
name: review-tests
description: Review test coverage completeness using an Explore subagent
model: sonnet
effort: low
context: fork
---

Review test case completeness against source code.

## Procedure

1. **Identify files**: Find the test file(s) and corresponding source file(s) being worked on.
   - Check `tests/` directory for recently modified test files
   - If ambiguous, ask the user which test and source files to review

2. **Launch Explore subagent**: Spawn an Explore subagent with the following instructions:
   - Read the test file(s) and corresponding source file(s)
   - Read `skills/_shared/test-design.md` for the Test Case Categories checklist
   - Evaluate test coverage against every category and sub-category in the checklist
   - For each category, report what IS covered, what is MISSING, and what is N/A (with reason)
   - For missing cases, suggest specific test descriptions

3. **Present results**: Show the subagent's findings to the user.
   - If gaps are found, propose specific test cases to add
   - Apply changes only after user approval

4. **Emit workflow sentinel** — two separate Bash calls, not chained:
   a. Compute staged-tests token: `TOKEN=$(node -e "const {computeStagedTestsToken}=require(process.env.AGENTS_CONFIG_DIR+'/hooks/workflow-gate/review-tests-evidence');const t=computeStagedTestsToken(process.cwd());process.stdout.write(t||'')")`
   b. If coverage adequate: `echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE: token=${TOKEN}>>"`
   c. If gaps or warnings: `echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS: token=${TOKEN} <one-line summary — no '>' characters>>>"`
   d. Skip when WORKFLOW_WRITE_TESTS_NOT_NEEDED was emitted (propagated skip).

## Rules

- Always launch the subagent — do not skip the review even if tests look complete
- The subagent must read actual file contents, not just file names
- The checklist definition lives in `skills/_shared/test-design.md` — do not duplicate it here
- Emit exactly one sentinel per review run: REVIEW_TESTS_COMPLETE on pass, REVIEW_TESTS_WARNINGS on any gap or warning.
- Do not emit REVIEW_TESTS_COMPLETE when WORKFLOW_WRITE_TESTS_NOT_NEEDED was emitted (skip path).
