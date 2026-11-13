#!/bin/bash
# Tests: bin/github-issues/issue-create-dispatch.sh, bin/github-issues/issue-create.sh, skills/issue-create/SKILL.md, skills/issue-create/scripts/run-bulk-dispatch.sh, skills/issue-create/scripts/run-phase5-record.sh, skills/workflow-init/SKILL.md
# Tags: issue-create, github, sub-issue, frontmatter, tests, scope:issue-specific
# L3 gap: real GitHub sub_issues POST acceptance, GraphQL databaseId availability, MSYS_NO_PATHCONV on
# live Windows Git Bash. Mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh
# category skill-orchestration.
# Tests the /issue-create skill: bin/github-issues/issue-create.sh (gh issue create wrapper),
# skills/issue-create/SKILL.md frontmatter, rules/github-issues.md "Issue creation", CLAUDE.md mention.
# RED: fails clean while bin/github-issues/issue-create.sh is missing.
# Cases run in parallel subshells (feature-issue-create-skill/case-runner.sh); output keeps definition order.

set -euo pipefail

# Pin both state dirs before anything runs; the cleanup trap targets the readonly root only.
IC_TMP_ROOT="$(mktemp -d)"; readonly IC_TMP_ROOT
trap 'cd /; rm -rf "${IC_TMP_ROOT:?}"' EXIT
export WORKFLOW_STATE_DIR="$IC_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$IC_TMP_ROOT/plans"
unset CLAUDE_CODE_SESSION_ID

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/issue-create.sh"
DISPATCH="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/issue-create-dispatch.sh"
SKILL_MD="$SCRIPT_CHECKOUT_ROOT/skills/issue-create/SKILL.md"
WORKFLOW_INIT_MD="$SCRIPT_CHECKOUT_ROOT/skills/workflow-init/SKILL.md"
RULES_GH="$SCRIPT_CHECKOUT_ROOT/rules/github-issues.md"
CLAUDE_MD="$SCRIPT_CHECKOUT_ROOT/CLAUDE.md"

# Early-exit: if the implementation is missing, report cleanly and exit.
if [[ ! -f "$TARGET" ]]; then
    echo "FAIL: bin/github-issues/issue-create.sh not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 30 failed"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_DIR="$SCRIPT_DIR/feature-issue-create-skill"

# case-runner.sh owns PASS/FAIL, pass/fail, run_with_timeout and the parallel runner.
# shellcheck source=/dev/null
. "$SUB_DIR/case-runner.sh"
# Sections load in this order (definition order = output order); section-scripts-existence defines BULK_SCRIPT / PHASE5_SCRIPT for the two #3013 sections after it.
for SECTION in section-mock section-create-sh section-doc-content-date section-dispatch-core section-dispatch-bulk section-phase5-resolver section-scripts-existence section-bulk-manifest-path section-phase5-bulk-record; do
    # shellcheck source=/dev/null
    . "$SUB_DIR/$SECTION.sh"
done
collect_cases

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
