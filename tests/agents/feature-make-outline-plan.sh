#!/usr/bin/env bash
# Tests: agents/outline-planner.md, agents/outline-reviewer.md, skills/_shared/codex-review-loop.md, skills/make-outline-plan/SKILL.md, hooks/stop-confirm-plan-guard.js
# Tags: outline, planning, sentinel, workflow, skill, scope:common
# Contract tests for make-outline-plan skill (Stage 2: outline-planner + outline-reviewer)
# L3 gap: live MOP-8 sentinel auto-selection and VS Code prose-summary rendering are
#   verifiable only in a live session; checked at WORKFLOW_USER_VERIFIED preflight
#   via bin/check-verification-gate.sh category: skill-orchestration.
# Exit 0 always — this is a contract test, not a CI gate yet.

if [ -z "$_TIMEOUT_WRAPPED" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

SKILL_MD="$HOME/.claude/skills/make-outline-plan/SKILL.md"
PLANNER_MD="$HOME/.claude/agents/outline-planner.md"
REVIEWER_MD="$HOME/.claude/agents/outline-reviewer.md"

# LOCAL_* point at the worktree copies (rules/test/fixture-isolation.md).
# Assertions about changes in this branch must use LOCAL_* — they fail pre-merge otherwise.
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_SKILL_MD="$SCRIPT_CHECKOUT_ROOT/skills/make-outline-plan/SKILL.md"
LOCAL_REVIEWER_MD="$SCRIPT_CHECKOUT_ROOT/agents/outline-reviewer.md"

# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

# assert_contains FILE PATTERN DESCRIPTION
# Greps FILE for PATTERN (extended regex). Prints PASS/FAIL.
assert_contains() {
    local file="$1"
    local pattern="$2"
    local desc="$3"

    if [ ! -f "$file" ]; then
        fail "$desc" "file not found: $file"
        return 1
    fi

    if grep -qE "$pattern" "$file"; then
        pass "$desc"
        return 0
    else
        fail "$desc" "pattern not found: $pattern"
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
        fail "$desc" "file not found: $file"
        return 1
    fi

    if grep -qE "$pattern" "$file"; then
        fail "$desc" "pattern unexpectedly found: $pattern"
        return 1
    else
        pass "$desc"
        return 0
    fi
}

echo "=== make-outline-plan contract tests ==="
echo ""

_PARTS_DIR="$(dirname "$0")/feature-make-outline-plan"

case_begin "normal-and-error-cases" "agents/outline-planner.md"
# shellcheck source=./feature-make-outline-plan/normal-and-error-cases.sh
. "$_PARTS_DIR/normal-and-error-cases.sh"
case_end

case_begin "issue-329-462" "skills/make-outline-plan/SKILL.md"
# shellcheck source=./feature-make-outline-plan/issue-329-462.sh
. "$_PARTS_DIR/issue-329-462.sh"
case_end

case_begin "issue-789" "hooks/stop-confirm-plan-guard.js"
# shellcheck source=./feature-make-outline-plan/issue-789.sh
. "$_PARTS_DIR/issue-789.sh"
case_end

case_begin "issue-1384-1287" "agents/outline-planner.md"
# shellcheck source=./feature-make-outline-plan/issue-1384-1287.sh
. "$_PARTS_DIR/issue-1384-1287.sh"
case_end

echo "=== Summary ==="
echo "PASS: $PASS  FAIL: $FAIL"

exit 0
