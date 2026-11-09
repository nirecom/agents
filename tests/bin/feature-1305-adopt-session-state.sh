#!/bin/bash
# Tests: bin/workflow/adopt-session-state, bin/workflow/lib/workflow-init/phases/adopt-prior-state.js
# Tags: workflow-state, session-inherit, adopt, regression-1305, scope:issue-specific, pwsh-not-required, TL2
# #1305 SD-4 — the EXPLICIT adoption path: the `adopt-session-state` CLI is its one execution
# point (CPR-SSOT); `/workflow-init`'s `adopt-prior-state` phase only routes interactive sessions to it.
# TL2 rationale: the CLI and the driver phase are plain node processes over real fixture files.
# TL3 gap: only a real interactive session proves ACTION=ask_user reaches AskUserQuestion and a real
# `$CI` host suppresses it; AD-9/AD-10 pin the env contract (CI / CLAUDE_NON_INTERACTIVE) explicitly.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CASE_DIR="$(dirname "$0")/feature-1305-adopt-session-state"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
    else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# --- fixture isolation (rules/test/fixture-isolation.md) -------------------
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
PLANS_DIR="$TMPDIR_BASE/plans"
TBASE="$TMPDIR_BASE/transcripts"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR" "$TBASE"
export WORKFLOW_STATE_DIR="$WORKFLOW_DIR"
export WORKFLOW_PLANS_DIR="$PLANS_DIR"

# Never resolve the live session: each case passes its own session-downstream sid explicitly.
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
# AD-9/AD-10 own these; neutralise whatever the host runner set.
unset CI 2>/dev/null || true
unset CLAUDE_NON_INTERACTIVE 2>/dev/null || true

# shellcheck source=./feature-1305-adopt-session-state/_lib.sh
. "$CASE_DIR/_lib.sh"
# shellcheck source=./feature-1305-adopt-session-state/cli.sh
. "$CASE_DIR/cli.sh"
# shellcheck source=./feature-1305-adopt-session-state/phase.sh
. "$CASE_DIR/phase.sh"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
