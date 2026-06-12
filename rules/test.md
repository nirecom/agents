# Testing

## Test Writing

Do not write or edit test files directly in the main conversation.

## Test Coverage Review

After writing test code, run `/review-tests`. WF-CODE-5 (`/write-code`) is blocked until both `write_tests` and `review_tests` are complete or both are skipped.

`/review-tests` records a staged-tests fingerprint at sentinel-emission time — re-editing test files after a passing review invalidates the pairing and forces re-review before `/write-code` can proceed.

Skip path: `echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>>"` symmetrically waives both gates (no separate skip sentinel for review).

## Test Execution Timeout

Always run tests with a timeout (default **120 seconds**). Tests that hang block the entire workflow.

See [test/macos-timeout.md](test/macos-timeout.md) for the portable `run_with_timeout` wrapper (macOS-compatible).

## Claude Code E2E Testing

See [test/claude-e2e.md](test/claude-e2e.md) for precautions when spawning `claude -p` in tests.

## Installer Testing

See [test/installer.md](test/installer.md) for silent installer test patterns (async completion, variable install paths, silent failure, idempotency).

## Test Layer Selection (L1 / L2 / L3)

| Layer | Definition | When required |
|---|---|---|
| L1 | Unit / narrow integration with mocked I/O | Default for pure logic |
| L2 | Broad integration: spawns real CLI / writes real files / uses real fixtures, but does not run the full host environment | Default when L3 cost is prohibitive |
| L3 | Full real environment: real `claude -p` session, real pwsh / bash shells, real Docker stack, real installer artifact | Required when the code path is a risk category AND L2 cannot fail when the user-visible path is broken |

### Closest-to-action verification

When an L2 fallback is taken, verification of the residual gap MUST happen at the closest workflow point before the action becomes irreversible (commit / merge / install). The `bin/check-verification-gate.sh` classifier runs as preflight inside the `<<WORKFLOW_USER_VERIFIED>>` emission protocol (`skills/_shared/user-verified.md`) and fires an `AskUserQuestion` only when the staged file set matches a risk category.

### Risk categories (SSOT)

The authoritative list of risk categories lives in `bin/check-verification-gate.sh` — its stdout records both the category token and the question text. Do not duplicate the list here. Current categories: `pwsh-required`, `hook-registration`, `skill-orchestration`, `installer`.

### L3 aspiration (long-term, out of scope for current implementation)

- `agents` repo: VS Code + Claude Code session reproduced inside a Docker/VM image so `claude -p` can run end-to-end on CI.
- `even` repo: real-device network testing across mobile + VPN; physical lab not yet wired.