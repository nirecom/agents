> Shared reference for `skills/write-tests` and `skills/review-tests`. Read explicitly by each skill's Step 1/2.

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

## Test Naming Convention (new tests only)

New test files follow `<area>-<issue-or-feature>-<topic>.sh` where `<area>` is one of `feature`, `fix`, `refactor`, `unit`, `main`.

Existing files are NOT renamed — `git blame` continuity is preserved. Frontmatter handles semantic grouping via `# Tags:`.
