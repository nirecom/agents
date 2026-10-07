#!/bin/bash
# Tests: bin/review-e2e-coverage
# Tags: scope:issue-specific, lint, hook-audit, review, e2e-coverage
# Verifies: Hook Audit table parsing, P1/P2/P3/OUT priorities, WARN/INFO/SKIPPED output, exit-0 invariant,
# self-test exclusion, --base/--all argument handling, graceful degradation.
# Layer: L2 (real script, real fixtures, real git diff, no full host environment).
# L3 gap: real WF-CODE-6 parallel-invocation wiring (status line consumed by /run-codex-review-loop /
# commit-push parsers); real cross-repo behavior from a non-worktree CWD (Windows path / drive-letter quirks).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# isolation (#2512): harness first, so the pass/fail/run_with_timeout below override harness's.
. "$AGENTS_ROOT/tests/lib/harness.sh"
SCRIPT="$AGENTS_ROOT/bin/review-e2e-coverage"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT
harness_isolate "$TMPDIR_BASE/isolation"

EMPTY_HOOKS_DIR="$TMPDIR_BASE/no-hooks"
mkdir -p "$EMPTY_HOOKS_DIR"
EMPTY_EXCLUDES="$TMPDIR_BASE/empty-excludes"
: > "$EMPTY_EXCLUDES"

SCRIPT_DIR="$(dirname "$0")/feature-973-review-e2e-coverage"

# shellcheck source=./feature-973-review-e2e-coverage/helpers.sh
. "$SCRIPT_DIR/helpers.sh"
# shellcheck source=./feature-973-review-e2e-coverage/cases-normal.sh
. "$SCRIPT_DIR/cases-normal.sh"
# shellcheck source=./feature-973-review-e2e-coverage/cases-edge.sh
. "$SCRIPT_DIR/cases-edge.sh"
# shellcheck source=./feature-973-review-e2e-coverage/cases-error-invariant.sh
. "$SCRIPT_DIR/cases-error-invariant.sh"
# shellcheck source=./feature-973-review-e2e-coverage/cases-all-mode.sh
. "$SCRIPT_DIR/cases-all-mode.sh"

echo ""
if [[ $ERRORS -gt 0 ]]; then
    echo "FAILED: $ERRORS test assertion(s) failed"
    exit 1
else
    echo "All tests passed"
fi
