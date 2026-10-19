#!/bin/bash
# Tests: bin/github-issues/issue-create-dispatch.sh, bin/github-issues/issue-create.sh, skills/issue-create/SKILL.md, skills/issue-create/scripts/run-bulk-dispatch.sh, skills/issue-create/scripts/run-phase5-record.sh, skills/workflow-init/SKILL.md
# Tags: issue-create, github, sub-issue, frontmatter, tests, scope:issue-specific
# L3 gap: real GitHub sub_issues POST acceptance, GraphQL databaseId availability, MSYS_NO_PATHCONV on
# live Windows Git Bash. Mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh
# category skill-orchestration.
# Tests the /issue-create skill: bin/github-issues/issue-create.sh (gh issue create wrapper),
# skills/issue-create/SKILL.md frontmatter, rules/github-issues.md "Issue creation", CLAUDE.md mention.
# RED: fails clean while bin/github-issues/issue-create.sh is missing.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/issue-create.sh"
DISPATCH="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/issue-create-dispatch.sh"
SKILL_MD="$SCRIPT_CHECKOUT_ROOT/skills/issue-create/SKILL.md"
WORKFLOW_INIT_MD="$SCRIPT_CHECKOUT_ROOT/skills/workflow-init/SKILL.md"
RULES_GH="$SCRIPT_CHECKOUT_ROOT/rules/github-issues.md"
CLAUDE_MD="$SCRIPT_CHECKOUT_ROOT/CLAUDE.md"

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

# Early-exit: if the implementation is missing, report cleanly and exit.
if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/issue-create.sh not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 30 failed"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_DIR="$SCRIPT_DIR/feature-issue-create-skill"

# shellcheck source=/dev/null
. "$SUB_DIR/section-mock.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-create-sh.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-doc-content-date.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-dispatch-core.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-dispatch-bulk.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-phase5-resolver.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-scripts-existence.sh"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
