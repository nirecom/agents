#!/usr/bin/env bash
# Tests: hooks/workflow-run-tests.js
# Tags: workflow, tests, runner, hook, bin, scope:common
# Tests for hooks/workflow-run-tests.js
# This PostToolUse hook marks run_tests from the RUN_CONTRACT line of tests/run-all.sh (or the worker-dispatch test-runner), never from a raw exit code.
# L3 gap: L2 only — cases pipe hand-built PostToolUse stdin JSON into the hook; no real Claude Code
#   session, settings.json hook registration, or PostToolUse event delivery is exercised.
#   L3 is deferred per #942 (gated on RUN_TL3 elsewhere); no claude -p E2E is added here.
#   Mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category: hook-registration.
# Dispatcher: shared helpers in main-workflow-run-tests/common.sh; case groups in normal-and-guard.sh,
#   error-and-edge.sh, error-and-edge-control.sh, idempotency-security.sh, contract-trust.sh.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# Windows-compatible path for require() inside node -e scripts:
# Git Bash /c/... paths fail in require() on Windows (Node maps /c/ to C:\c\ not C:\).
DOTFILES_WIN="$(cygpath -m "$DOTFILES_DIR" 2>/dev/null || echo "$DOTFILES_DIR")"
RUN_TESTS_HOOK="$DOTFILES_DIR/hooks/workflow-run-tests.js"

TMPDIR_BASE=$(mktemp -d)
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md). Dual-pin: pinning only
# CLAUDE_WORKFLOW_DIR routes hook state into the fixture while any supervisor
# emitter on the same code path still resolves ~/.workflow-plans and appends to
# the developer's real audit trail. Exported once here so every child `node`
# inherits both, and the inherited live session IDs are cleared so a hook cannot
# resolve — and mutate — the real session running this suite.
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/workflow-plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)/main-workflow-run-tests"

# shellcheck source=./main-workflow-run-tests/common.sh
. "$SCRIPT_DIR/common.sh"
# shellcheck source=./main-workflow-run-tests/normal-and-guard.sh
. "$SCRIPT_DIR/normal-and-guard.sh"
# shellcheck source=./main-workflow-run-tests/error-and-edge.sh
. "$SCRIPT_DIR/error-and-edge.sh"
# shellcheck source=./main-workflow-run-tests/error-and-edge-control.sh
. "$SCRIPT_DIR/error-and-edge-control.sh"
# shellcheck source=./main-workflow-run-tests/idempotency-security.sh
. "$SCRIPT_DIR/idempotency-security.sh"
# shellcheck source=./main-workflow-run-tests/contract-trust.sh
. "$SCRIPT_DIR/contract-trust.sh"
# shellcheck source=./main-workflow-run-tests/detection-matrix.sh
. "$SCRIPT_DIR/detection-matrix.sh"
# shellcheck source=./main-workflow-run-tests/robustness.sh
. "$SCRIPT_DIR/robustness.sh"
# shellcheck source=./main-workflow-run-tests/quoted-arg-and-provenance.sh
. "$SCRIPT_DIR/quoted-arg-and-provenance.sh"

run_normal_and_guard_tests
run_error_and_edge_tests
run_error_and_edge_control_tests
run_idempotency_security_tests
run_contract_trust_tests
run_detection_matrix_tests
run_robustness_tests
run_quoted_arg_and_provenance_tests

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
