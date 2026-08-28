> Detail file of `skills/_shared/test-design.md`. Read it when the change involves a security boundary, a guard, or a classifier fix.

## Security / Protection Fix Test Patterns (#1001)

Tests for protection fixes (security boundaries, input sanitization, access-control
enforcement) must apply all three patterns below. Omitting any one creates a structural
coverage gap.

### Pattern 1 — Negative assertion

For rejected input, directly assert that the protected resource was NOT modified.
Asserting only exit code or error message is insufficient.

Example: for a fix that prevents symlink following, assert both that the command exited
non-zero AND that the link target file remains unchanged.

### Pattern 2 — Attack scenario structure

Structure the bugfix test so it FAILs against the unpatched code:
1. Set up preconditions that reproduce the vulnerable state before the fix.
2. Execute the action under test.
3. Assert that the attack was blocked (protected resource unchanged).

This provides test-layer evidence that complements the workflow-level fail-before-fix gate.

### Pattern 3 — Paired gap (Skipped-Because)

Scenarios not implementable at the current layer (require fault injection, cannot
reproduce in CI, etc.) must be left as comments rather than deleted:

# SKIPPED: <scenario description>
# Because: <reason — e.g. "requires real root access", "fault injection not possible at L2">
# L3 gap: <what only the real environment would catch>

One Skipped-Because comment per scenario, placed adjacent to the relevant test code.

### Pattern 4 — Classifier both-direction coverage

For a classifier or guard target, apply the **Classifier / guard cases** bullet under
`## Test Case Categories` in `skills/_shared/test-design.md`.
Cover both the rejection path and the allow path (sanctioned input).
