#!/usr/bin/env bash
# tests/feature-clarify-intent/_lib.sh
# Shared helpers for the feature-clarify-intent split test suite.
#
# Sourced by each split file (static-series.sh / companion-precheck-series.sh)
# so they can also run standalone. Provides the timeout re-exec guard, path
# constants, PASS/FAIL counters, and assert_contains / assert_absent.
#
# Idempotent — guarded so multiple sources do not redefine state.

if [ -n "${_CLARIFY_INTENT_LIB_SOURCED:-}" ]; then
    return 0
fi
_CLARIFY_INTENT_LIB_SOURCED=1

# Timeout guard: if running without the sentinel, re-exec under timeout.
# $0 is the sourcing series file (or the dispatcher), so standalone runs are
# wrapped too; dispatcher-launched runs inherit _TIMEOUT_WRAPPED and skip.
if [ -z "${_TIMEOUT_WRAPPED:-}" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

# Deployed skill (may lag the worktree until the PR merges).
SKILL_MD="$HOME/.claude/skills/clarify-intent/SKILL.md"
# Note: $HOME/.claude/skills/ is the *skill code* location and is unaffected
# by the workflow-plans-dir migration. Only planning artifact output paths
# (formerly ~/.claude/plans/) move to ~/.workflow-plans/.

# Worktree-relative paths — for assertions targeting unmerged changes.
LOCAL_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_SKILL_MD="$LOCAL_REPO_ROOT/skills/clarify-intent/SKILL.md"

PASS=0
FAIL=0

pass() {
    echo "PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "FAIL: $1"
    FAIL=$((FAIL + 1))
}

# assert_contains FILE PATTERN DESCRIPTION
# Greps FILE for PATTERN (extended regex). Prints PASS/FAIL.
assert_contains() {
    local file="$1"
    local pattern="$2"
    local desc="$3"

    if [ ! -f "$file" ]; then
        fail "$desc (file not found: $file)"
        return 1
    fi

    if grep -qE "$pattern" "$file"; then
        pass "$desc"
        return 0
    else
        fail "$desc (pattern not found: $pattern)"
        return 1
    fi
}

# assert_absent FILE PATTERN DESCRIPTION
# Asserts FILE does NOT contain PATTERN. Prints PASS/FAIL.
assert_absent() {
    local file="$1"
    local pattern="$2"
    local desc="$3"

    if [ ! -f "$file" ]; then
        fail "$desc (file not found: $file)"
        return 1
    fi

    if grep -qE "$pattern" "$file"; then
        fail "$desc (pattern unexpectedly found: $pattern)"
        return 1
    else
        pass "$desc"
        return 0
    fi
}
