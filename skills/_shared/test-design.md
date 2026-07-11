> Shared reference for `skills/write-tests` and `skills/review-tests`. Read explicitly by each skill's Step 1/2.

## Priority Tiers

Classify each coverage gap by severity before reporting.

- critical: missing test would hide a security breach, data loss, or silent regression. Blocks COMPLETE.
- high: missing test would miss a primary feature-path regression. Blocks COMPLETE.
- medium: useful but not regression-critical (error paths, secondary flows). Does not block COMPLETE.
- low: nice-to-have (edge cases, optional behaviors, performance). Does not block COMPLETE.

Only critical and high gaps must be resolved before marking review COMPLETE.
Report medium and low gaps as advisory only.

## Test Case Categories

- **Normal cases**: Expected inputs and typical usage
- **Error cases**: Invalid inputs, missing resources, permission errors
- **Edge cases**: Boundary values and unexpected-but-valid inputs
  - Numeric: 0, negative, `MAX_INT`, off-by-one
  - String: empty `""`, `null`, single character, extremely long
  - Collection: empty array/list, single element, duplicates
  - File/path: non-existent, empty file, special characters in name

- **Idempotency cases**: Re-running the same operation produces the same result without side effects
  - File/config: re-running doesn't duplicate entries (e.g., same line appended twice to `.bashrc`), template generation produces identical output
  - Cleanup: deletion/uninstall of already-removed targets doesn't error

- **Security cases**: Verify that security boundaries hold under adversarial input
  Source: OWASP ASVS V8 (Data Protection), OWASP WSTG (Input Validation), CWE Top 25
  - Secret leakage: secrets never appear in output, logs, temp files, or error messages (OWASP ASVS V8)
  - Input injection: malicious CLI args, file paths, and shell metacharacters are rejected or sanitized (OWASP WSTG, CWE-78 OS Command Injection, CWE-22 Path Traversal)
  - Permission: operations respect access control boundaries — unprivileged callers are denied (OWASP ASVS V4 Access Control)
  - Prompt injection: LLM/agent inputs from untrusted sources do not override system instructions or trigger unintended tool calls (OWASP LLM Top 10 LLM01, MCP Top 10 MCP06)
  - Security idempotency: re-running security-relevant operations (e.g., permission grants, secret rotation) does not escalate privileges or leave duplicate entries (extension of Idempotency cases)

## Security vs Test Compatibility

- Never weaken new security to preserve old tests — update the tests instead.

## Test File Naming

Name test files after the branch they belong to, replacing `/` with `-`:

```
tests/<branch-type>-<branch-name>.<ext>
```

- `feature/claude-rules` → `tests/feature-claude-rules.sh`
- `fix/ssh-keys` → `tests/fix-ssh-keys.sh`
- main direct work: `tests/main-<name>.sh`
- Multiple files per feature: add a suffix (e.g., `feature-claude-rules-global.sh`)

Python (pytest) requires a `test_` prefix for auto-discovery:

| Language | Extension |
|---|---|
| Python (pytest) | `test_<branch-type>-<branch-name>.py` |
| bash | `.sh` |
| PowerShell (Pester) | `.Tests.ps1` |

## Test Layer Selection

Follow Martin Fowler's narrow/broad integration distinction and Kent C. Dodds'
Testing Trophy: pick the lowest test layer that can actually fail when the code
under test is broken.

| Layer | What it must catch |
|---|---|
| Static (schema / lint / types) | Config file structure errors, typos in known schemas |
| Unit | Pure logic of a single function with all I/O mocked |
| Narrow integration | Module reads real config files / env vars / fixtures |
| Broad integration | Real subprocess, real filesystem, real plugin/hook registration |
| Smoke (post-install) | "Is it actually wired up in the real environment?" |

### Mandatory integration or E2E coverage

Add an integration or E2E test (not just unit) when the change touches any of
the following — unit tests are structurally blind to these failure modes:

1. **Configuration files** (`settings.json`, YAML, TOML, etc.) — load the real
   file and assert the feature activates. Consider schema validation as a static
   test.
2. **Hook / plugin / event-handler registration** — the test must verify the
   hook actually fires in the real host process, not just that the handler
   function works when called directly.
3. **Subprocess boundaries** — spawn the real CLI and assert on
   stdout/stderr/exit code/side-effect files.
4. **Cross-module wiring** added or modified (DI, routing, event bus).
5. **Regression for a bug that slipped past unit tests** — the regression test
   must live at the layer that would have caught it.

### Fail-before-fix (BUGFIX sessions only, mandatory)

For BUGFIX sessions (`fix/*` branch), tests must be written and run BEFORE the implementation:
- Write tests that target the broken behavior → confirm they fail.
- Write the fix → confirm tests now pass.
- This fail-before-fix evidence is enforced by the workflow gate: `write_tests` and `review_tests` cannot be skipped in BUGFIX sessions.

### L2 fallback — required gap documentation

When you choose L2 over L3, you MUST add a `# L3 gap` block to the test file header documenting what L3 would additionally verify. Template:

    # L3 gap (what this test does NOT catch):
    # - <observable behavior 1 that only the real environment exhibits>
    # - <observable behavior 2 ...>
    # Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
    # via bin/check-verification-gate.sh category: <category-token>.

A test file without an L3 gap block is treated as a claim of full L3 coverage. `/review-tests` will challenge L1/L2 tests lacking this block when the file matches a risk category.

### Deciding whether to write an integration test

Ask: *"If someone deleted the registration / misplaced the config key / renamed
the event, would my unit tests still pass?"* If yes, a unit test is not enough.

## Required Frontmatter

Every `tests/*.sh` file (excluding `tests/_archive/`) must carry exactly two single-line
headers within the first 10 lines, right after the shebang and filename comment:

- `# Tests: <path1>, <path2>` — comma-separated repo-relative source paths (forward slash). Used by `bin/audit-tests.sh` for staleness checks and by Tier 2 semantic selection.
- `# Tags: <kw1>, <kw2>` — comma-separated kebab-case keywords. Used by the LLM Tier 2 matcher in `skills/run-tests/SKILL.md`.

Both lines are **single-line** — no multi-line blocks, no YAML-style `- ` continuation. Long lines are acceptable; parsers rely on single-line format.

- Recognized `# Tags:` values (non-exhaustive): `pwsh-required` — this file exercises PowerShell-specific behavior and must be re-verified under pwsh before merge. `pwsh-not-required` — explicit opt-out for files that mention `powershell` only in comments or docs.

## Scope Classification

- Filename convention classifies test files:
  - `feature-NNN-*` (numeric issue ID after `feature-`) = `scope:issue-specific`
  - All other files = `scope:common`
- Recognized `# Tags:` values: `scope:issue-specific`, `scope:common`.
- New or edited test files MUST include `scope:issue-specific` or `scope:common` in their `# Tags:`.
- Existing files without this tag are classified by filename convention; backfill of existing files is not required.

## Size Limits

- Same limits as code files: WARN at >300 lines, HARD at >500 lines.
- Split mechanism: same as code — `tests/<name>/` sibling folder with a dispatcher `.sh`. See `rules/coding/file-split.md`.
- Canonical split example: `tests/main-workflow-skip-sentinels/` (PR #867).
- `tests/_archive/` is excluded from size checks.

## Test Naming Convention (new tests only)

New test files follow `<area>-<issue-or-feature>-<topic>.sh` where `<area>` is one of `feature`, `fix`, `refactor`, `unit`, `main`.

Existing files are NOT renamed — `git blame` continuity is preserved. Frontmatter handles semantic grouping via `# Tags:`.

## Table-Driven Tests (required when changing parsers, regex constants, or allowlists)

When modifying parsers, regex constants, or allowlists (e.g. sentinel-patterns.js,
bash-write-patterns.js, command-parser.js, scan-outbound.sh), use table-driven patterns
in the corresponding test file.

### Standard bash pattern

while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    got=$(eval_subject "$input")
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
case-name-1 | input value 1 | expected-1
case-name-2 | input value 2 | expected-2
TABLE

Define assert_eq inline in each test file (no shared library):

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}

- The first column `name` is injected into every assertion message (equivalent to Go's `t.Run(name)`).
- `IFS='|'` allows spaces inside fields without quoting. `read -r` prevents backslash expansion.
- Blank lines and `#` comment lines in the heredoc are skipped.

### Equivalent JS pattern

A JS test is considered table-driven when it uses:
- `cases.forEach()` iteration, or
- `for (const {name, input, want} of cases)` iteration,
- with `name` included in the assertion message inside each iteration.

### When this rule applies

Apply when any of the following is true:
- Adding or modifying regex constants in a pattern file.
- Testing the same function with 2 or more different inputs.
- An existing test file for a parser/regex/allowlist target has fewer than 2 cases per logical path.

## Mutation Probe (lightweight regex kill verification)

Run a mutation probe against parser/regex files when:
- Adding a new regex constant (verify the test FAILs when that constant is removed).
- Fixing a regex bug (verify the regression test FAILs against the unpatched code).

### Running the probe

bin/mutation-probe.sh <target-js-file>

Probe behavior:
1. Identifies regex constants in the target file (single-line `const NAME = /regex/;` form).
2. Replaces each constant with `/(?!)/` (never-match) in a temporary copy and runs the tests.
3. Records PASS and FAIL counts.
4. Computes mutation score = (FAIL count / total) × 100% and reports it.

Required threshold: at least 80% of probed regex constants must cause a test FAIL.

### Known limitation (partial coverage)

`bin/mutation-probe.sh` targets single-line form (`const NAME = /regex/;`) only.
Not covered in the current version:
- Two-line form (`const NAME =\n  /regex/;`): common in sentinel-patterns.js.
- Patterns inside object literals (`regex` field of `WRITE_PATTERNS` array): bash-write-patterns.js.

When the probe runs against these files it prints the detected constant count and a
"partial coverage" warning. Full coverage is planned for T1-E2 (Stryker).

### Relationship to table-driven tests

- Table-driven: parametrically covers input/output cases.
- Mutation probe: verifies that each regex constant is actually exercised by tests (not dead code).

Run both when adding to a parser/regex file.

## False-Green Detection

False-green tests (tests that always pass regardless of code state) are forbidden.
The following patterns are detected by `bin/check-false-green.sh`.

### Forbidden patterns

1. Empty test function/block with no assertions.
2. Assertion where `want` and `got` are the same literal: `assert_eq name "x" "x"` (both sides hardcoded).
3. Calling `pass "..."` without checking an exit code (unchecked pass).

### Scope of bin/check-false-green.sh

Grep-based detection. Pattern 2 is a hard failure (FALSE-GREEN, exit code 1). Bare `pass`
near the start of a line is a WARN (exit code 0). Patterns 1 and 3 (requiring AST analysis)
are future work.

The bare-pass WARN includes false positives (e.g. the `pass()` function definition line),
so it is not a hard CI failure.

### Background

Motivated by 11 dead assertions found and fixed after the fact in PR #865.
Applying the false-green detector at authoring time prevents recurrence.

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
