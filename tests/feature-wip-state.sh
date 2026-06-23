#!/bin/bash
# Tests: agents/issues/42, bin/gh, bin/github-issues/wip-state.sh, bin/workflow-plans-dir
# Tags: issue-create, github, workflow, issues, plans
# Tests for bin/github-issues/wip-state.sh — Issue #362 WIP signaling helper.
#
# Helper has four verbs: set, check, clear, setup.
#   - set <N>:   write fingerprint (text field) BEFORE Status=In Progress.
#   - check <N>: print same|other|none.
#   - clear <N>: Status=Done + fingerprint="" + delete lock file (idempotent).
#   - setup:     one-shot ID discovery via gh api graphql; append to .env.
#
# 30 test cases per detail.md §"tests/feature-wip-state.sh (new)".
# Inline-gh-mock pattern from tests/feature-issue-create-skill.sh.
#
# RED: this suite fails clean while bin/github-issues/wip-state.sh is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$AGENTS_DIR/bin/github-issues/wip-state.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# Early-exit: if the helper is missing, report cleanly and exit.
if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/wip-state.sh not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 30 failed"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_DIR="$SCRIPT_DIR/feature-wip-state"
# shellcheck source=/dev/null
. "$SUB_DIR/setup.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/set.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/check.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/clear.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/cross-verb.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/t-new-1-5.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/t-new-6-11.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/resolver.sh"

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
