#!/bin/bash
# Tests: agents/issues/, agents/issues/100/sub_issues, agents/issues/201, agents/issues/201/sub_issues, agents/issues/42, agents/issues/9999, bin/gh, bin/github-issues/issue-create-dispatch.sh, bin/github-issues/issue-create.sh, skills/issue-create/SKILL.md, skills/workflow-init/SKILL.md
# Tags: issue-create, github, sub-issue, frontmatter, tests, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
# - Real GitHub API: actual sub_issues POST acceptance, GraphQL databaseId availability
# - MSYS_NO_PATHCONV interaction on live Windows Git Bash sessions
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
#
# Tests for the new /issue-create skill:
#   bin/github-issues/issue-create.sh  — bash wrapper around gh issue create
#   skills/issue-create/SKILL.md       — YAML frontmatter skill definition
#   rules/github-issues.md             — ## Issue creation section
#   CLAUDE.md                          — /issue-create mention
#
# RED: this suite fails clean while bin/github-issues/issue-create.sh is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$AGENTS_DIR/bin/github-issues/issue-create.sh"
DISPATCH="$AGENTS_DIR/bin/github-issues/issue-create-dispatch.sh"
SKILL_MD="$AGENTS_DIR/skills/issue-create/SKILL.md"
WORKFLOW_INIT_MD="$AGENTS_DIR/skills/workflow-init/SKILL.md"
RULES_GH="$AGENTS_DIR/rules/github-issues.md"
CLAUDE_MD="$AGENTS_DIR/CLAUDE.md"

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

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
