#!/bin/bash
# tests/fix-1899-origin-repo-resolver/_lib.sh — shared scaffolding
#
# Sourced by each split file so they also run standalone. Provides: path
# constants, pass/fail/assert_eq helpers, run_with_timeout, an isolated TMP
# sandbox, the mk_repo/call_resolver fixture harness, and finish().
#
# Tests: bin/github-issues/lib/origin-repo.sh, bin/github-issues/lib/board-card.sh, skills/issue-close-finalize/scripts/pre-flight.sh
# Tags: origin-resolution, github-issues, board-card, pre-flight, table-driven, security, path-traversal, authority-anchoring, TL2, scope:issue-specific
#
# NOT a test file (no frontmatter in first 10 lines; excluded from
# dispatcher's SPLIT_GROUPS). Idempotent — guarded against re-sourcing.

if [ -n "${_FIX1899_ORIGIN_LIB_SOURCED:-}" ]; then
    return 0
fi
_FIX1899_ORIGIN_LIB_SOURCED=1

set -u

# Repo root, resolved relative to this lib (tests/fix-1899-origin-repo-resolver/).
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AGENTS_CONFIG_DIR="$AGENTS_DIR"
ORIGIN_LIB="$AGENTS_DIR/bin/github-issues/lib/origin-repo.sh"
BOARD_CARD_LIB="$AGENTS_DIR/bin/github-issues/lib/board-card.sh"
PRE_FLIGHT="$AGENTS_DIR/skills/issue-close-finalize/scripts/pre-flight.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

TMP="$(mktemp -d)"
# Fixture isolation (rules/test/fixture-isolation.md): nothing here may reach the
# developer's real HOME, workflow state, or plans dir. CLAUDE_WORKFLOW_DIR and
# WORKFLOW_PLANS_DIR are pinned as a PAIR — pinning one alone is the
# supervisor-contamination bug.
export HOME="$TMP/home"
export CLAUDE_WORKFLOW_DIR="$TMP/workflow"
export WORKFLOW_PLANS_DIR="$TMP/plans"
mkdir -p "$HOME" "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
_fix1899_origin_cleanup() { cd "$TMP/.." 2>/dev/null || true; rm -rf "$TMP"; }
trap _fix1899_origin_cleanup EXIT

# mk_repo <name> [origin-url] -> echoes the fixture path
mk_repo() {
    local dir="$TMP/repos/$1"
    rm -rf "$dir"; mkdir -p "$dir"
    git -C "$dir" init -q
    # MANDATORY per rules/test/fixture-isolation.md — keeps the installed
    # pre-commit hook from firing inside the fixture.
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config user.email "fixture@example.com"
    git -C "$dir" config user.name "Fixture"
    if [ "${2:-__NONE__}" != "__NONE__" ]; then
        git -C "$dir" remote add origin "$2"
    fi
    printf '%s' "$dir"
}

# call_resolver <dir> -> prints "<rc>|<stdout>"
call_resolver() {
    local out rc
    out=$(run_with_timeout 20 bash -c '
        set -u
        [ -f "$1" ] || { printf "ERR:lib-missing"; exit 90; }
        # shellcheck disable=SC1090
        . "$1"
        command -v resolve_origin_owner_repo >/dev/null 2>&1 || { printf "ERR:fn-missing"; exit 91; }
        resolve_origin_owner_repo "$2"
    ' _ "$ORIGIN_LIB" "$1" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$out"
}

# Print results summary and exit with appropriate code.
finish() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ] && exit 0 || exit 1
}
