#!/bin/bash
# Tests: agents/issues/42, bin/gh, bin/github-issues/wip-state.sh, bin/workflow-plans-dir, bin/github-issues/lib/board-card.sh, bin/github-issues/lib/origin-repo.sh
# Tags: issue-create, github, workflow, issues, plans, scope:issue-specific
# Tests for bin/github-issues/wip-state.sh — Issue #362 WIP signaling helper.
#
# Helper has five verbs: set, check, clear, abandon, setup.
#   - set <N>:     write fingerprint (text field) BEFORE Status=In Progress.
#   - check <N>:   print same|other|none.
#   - clear <N>:   Status=Done + fingerprint="" + delete lock file (idempotent).
#   - abandon <N>: OPEN-only; Status=Todo + fingerprint="" + delete lock (HARD writes).
#   - setup:       one-shot ID discovery via gh api graphql; append to .env.
#
# 30 base cases per detail.md §"tests/feature-wip-state.sh" + 38 abandon cases.
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

# ---------------------------------------------------------------------------
# make_origin_fixture <dir> [<origin-url>]
#   #1899: repository identity is now resolved from the ORIGIN remote via
#   bin/github-issues/lib/origin-repo.sh, NOT from `gh repo view`. Any fixture
#   CWD that a wip-state verb runs from must therefore be a git repo carrying a
#   github.com origin, or resolution fails before the assertion point.
#
#   Creates <dir>, git-inits it, disables git hooks (rules/test/fixture-isolation.md),
#   and adds the origin remote (default https://github.com/nirecom/agents.git).
#   Deliberately does NOT create WORKTREE_NOTES.md — priority-6 session-id
#   resolution reads it, and the SID-isolation cases depend on its absence.
# ---------------------------------------------------------------------------
make_origin_fixture() {
    local dir="$1"
    local url="${2:-https://github.com/nirecom/agents.git}"
    mkdir -p "$dir"
    git -C "$dir" init -q >/dev/null 2>&1
    git -C "$dir" config core.hooksPath /dev/null >/dev/null 2>&1
    git -C "$dir" remote remove origin >/dev/null 2>&1 || true
    git -C "$dir" remote add origin "$url" >/dev/null 2>&1
}

# make_git_fixture_no_origin <dir> — git repo with NO origin remote.
make_git_fixture_no_origin() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q >/dev/null 2>&1
    git -C "$dir" config core.hooksPath /dev/null >/dev/null 2>&1
    git -C "$dir" remote remove origin >/dev/null 2>&1 || true
}

# Early-exit: if the helper is missing, report cleanly and exit.
if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/wip-state.sh not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 68 failed"
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
. "$SUB_DIR/abandon.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/cross-verb.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/t-new-1-5.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/t-new-6-11.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/resolver.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/t-1082.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/origin-repo-1899.sh"

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
