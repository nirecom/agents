#!/usr/bin/env bash
# tests/hooks/feature-supervisor-shim-injection.sh
# Tests: hooks/supervisor-off-proposal-shim.js
# Tags: supervisor, em-supervisor, shim, injection, adversarial, scope:issue-specific, pwsh-not-required
# L3 gap (what this test does NOT catch):
# - The shim firing as a real PreToolUse hook inside a live claude -p session
# - Multi-turn transcript context where prior assistant output provides framing
# - Shellquoting edge cases when Claude Code assembles the Bash command string
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

# C6 [MEDIUM/security]: Table-driven adversarial cases for supervisor-off-proposal-shim.js.
# Verifies the shim blocks genuine OFF-sentinel emit commands and passes through
# look-alike patterns that appear in grep, heredocs, quotes, and other non-emit contexts.
# RED-EXPECTED (all FAIL) until /write-code creates supervisor-off-proposal-shim.js.

set -u

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _SCRIPT_CHECKOUT_ROOT_NODE="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"
else
    _SCRIPT_CHECKOUT_ROOT_NODE="$SCRIPT_CHECKOUT_ROOT"
fi

SHIM="$SCRIPT_CHECKOUT_ROOT/hooks/supervisor-off-proposal-shim.js"
WRITER_NODE="$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/lib/supervisor-state-schema.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'supvsr_shim'; }

if [ ! -f "$SHIM" ]; then
    fail "C6-all: supervisor-off-proposal-shim.js not present (RED-EXPECTED — Change 5 not yet implemented)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

if ! command -v node >/dev/null 2>&1; then
    skip "C6-all: node not available"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-supervisor-shim-injection"
# shellcheck source=tests/hooks/feature-supervisor-shim-injection/c6-adversarial.sh
. "$_DIR/c6-adversarial.sh"
# shellcheck source=tests/hooks/feature-supervisor-shim-injection/c4-c5.sh
. "$_DIR/c4-c5.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
