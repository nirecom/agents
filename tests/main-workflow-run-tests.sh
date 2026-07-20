#!/usr/bin/env bash
# Tests: hooks/workflow-run-tests.js
# Tags: workflow, tests, runner, hook, bin, scope:common
# L3 gap (what this test does NOT catch):
# - This suite exercises the hook at L2: each case pipes a hand-built PostToolUse
#   stdin JSON payload directly into hooks/workflow-run-tests.js and asserts on the
#   resulting workflow-state file. It does NOT run a real Claude Code session.
# - Real Claude Code session where PostToolUse fires after a live bash test run
# - Actual settings.json hook registration and PostToolUse event delivery (does the
#   harness actually invoke this hook, with this stdin shape, on a real Bash tool call?)
# That residual registration/event-delivery verification is L3 and is DEFERRED per #942
# (full claude -p E2E containerization is out of scope; L3 e2e is gated on RUN_TL3
# elsewhere). No claude -p E2E test is added here — this is a documented skip record.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
# Tests for hooks/workflow-run-tests.js
# This hook is a PostToolUse handler that auto-marks run_tests based on Bash command + exit code.
#
# Dispatcher: shared helpers/fixtures live in main-workflow-run-tests/common.sh;
# case groups live in normal-and-guard.sh, error-and-edge.sh,
# error-and-edge-control.sh, idempotency-security.sh, contract-trust.sh.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Windows-compatible path for require() inside node -e scripts:
# Git Bash /c/... paths fail in require() on Windows (Node maps /c/ to C:\c\ not C:\).
DOTFILES_WIN="$(cygpath -m "$DOTFILES_DIR" 2>/dev/null || echo "$DOTFILES_DIR")"
RUN_TESTS_HOOK="$DOTFILES_DIR/hooks/workflow-run-tests.js"

TMPDIR_BASE=$(mktemp -d)
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

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

run_normal_and_guard_tests
run_error_and_edge_tests
run_error_and_edge_control_tests
run_idempotency_security_tests
run_contract_trust_tests
run_detection_matrix_tests
run_robustness_tests

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
