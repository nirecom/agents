# Testing

## Test Writing

Do not write or edit test files directly in the main conversation.

## Test Coverage Review

After writing test code, run `/review-tests`. WF-CODE-5 (`/write-code`) is blocked until both `write_tests` and `review_tests` are complete or both are skipped.

`/review-tests` records a staged-tests fingerprint at sentinel-emission time — re-editing test files after a passing review invalidates the pairing and forces re-review before `/write-code` can proceed.

Skip path: `echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: {reason}>>"` symmetrically waives both gates (no separate skip sentinel for review).

## Test Execution Timeout

Always run tests with a timeout (default **120 seconds**). Tests that hang block the entire workflow.

See [test/macos-timeout.md](test/macos-timeout.md) for the portable `run_with_timeout` wrapper (macOS-compatible).

## Claude Code E2E Testing

See [test/claude-e2e.md](test/claude-e2e.md) for precautions when spawning `claude -p` in tests.

## Installer Testing

See [test/installer.md](test/installer.md) for silent installer test patterns (async completion, variable install paths, silent failure, idempotency).

## Test Layer Selection (L1 / L2 / L3 / L4)

Two axes are separated here (do not conflate them): **substrate fidelity** (how real the environment is) rises L1→L2→L3; **pipeline scope** (how much of the pipeline one run exercises) is what distinguishes L3 (single component/seam) from L4 (whole pipeline).

| Layer | Definition | When required |
|---|---|---|
| L1 | Unit / narrow integration with mocked I/O | Default for pure logic |
| L2 | Broad integration: spawns real CLI / writes real files / uses real fixtures, but does not run the full host environment | Default when L3 cost is prohibitive |
| L3 | Real environment exercising a **single component/seam**: one hook via real `claude -p`, one skill, real pwsh / bash shell, real Docker stack, or real installer artifact | Required when the code path is a risk category AND L2 cannot fail when the single-component path is broken |
| L4 | Real environment exercising the **whole pipeline end-to-end** (workflow-init → Final Report, or a named multi-step skill chain) — the only tier that earns the term "E2E" | Required for cross-step / cross-hook integrity that no single-seam L3 can catch |

"E2E" is reserved for L4. A single-hook real-`claude -p` seam test is L3, not E2E.

### Test file naming by layer

- **L1 / L2** (default, always-run): named by subsystem (`feat-`, `fix-`, `cc-`, `bin-`, `enforce-`, …). No layer prefix. Layer is recorded in `# Tags:`.
- **L3 / L4** (real-environment, `RUN_E2E`-gated): carry a layer prefix — `L3-<category>-<name>` (e.g. `L3-hook-workflow-mark`, `L3-installer-…`), `L4-<name>` (e.g. `L4-workflow-…`). The prefix marks the gated expensive tier so it is visible in `ls tests/` and greppable as a group.
- Never embed an issue number in an L3/L4 filename: retire policies key on `feature-<N>` names and would delete permanent coverage after the issue closes.

### Closest-to-action verification

When an L2 fallback is taken, verification of the residual gap MUST happen at the closest workflow point before the action becomes irreversible (commit / merge / install). The `bin/check-verification-gate.sh` classifier runs as preflight inside the `<<WORKFLOW_USER_VERIFIED>>` emission protocol (`skills/_shared/user-verified.md`) and fires an `AskUserQuestion` (before commit or merge) only when `RUN_E2E=on` and the staged file set matches a risk category (when `RUN_E2E=off`, the ask is suppressed and categories are logged only).

### Risk categories (SSOT)

The authoritative list of risk categories lives in `bin/check-verification-gate.sh` — its stdout records both the category token and the question text. Do not duplicate the list here. Current categories: `pwsh-required`, `hook-registration`, `skill-orchestration`, `installer`.

### L4 aspiration

See [test/claude-e2e.md](test/claude-e2e.md) `## Acceptance Criteria for claude -p E2E Tests` for the current real-`claude -p` test contract. Full-pipeline L4 (workflow-init → Final Report driven through a real TTY) is tracked as a roadmap item (#1543) and is out of scope for #942 / #943.