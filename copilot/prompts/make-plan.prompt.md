---
name: make-plan
description: Produce an implementation plan via draft, self-critique, and revision, then present for approval.
---

Produce an implementation plan for the current task.

## Steps

1. **Draft** — write a concrete implementation plan:
   - Context: why this change is needed
   - Approach: step-by-step with file paths and function names
   - Files to modify or create
   - Verification: how to test end-to-end

2. **Critique** — review your own draft for:
   - Missing edge cases or error handling
   - Security implications (secret leakage, injection, excessive permissions)
   - Cross-platform gaps (if the change touches `install/win/`, check `install/linux/`, and vice versa)
   - Existing utilities that could be reused instead of new code
   - Anything that would cause existing tests to break

3. **Revise** — update the draft to address all critique findings.

4. **Present** the final plan. Include a verification section describing how to test the changes.

## Rules

- Plans must be specific: file paths, function names, exact key names — no vague references.
- Do not start implementing. Present the plan and wait for approval.
- If research is needed before planning (unknown API, unfamiliar library), say so explicitly.
