#!/bin/bash
# tests/bin/feature-commit-gate-redesign.sh
# Tests: bin/review-code-codex, hooks/workflow-gate.js, hooks/workflow-mark.js
# Tags: workflow, gate, hook, worktree, codex, scope:issue-specific
# Integration tests for the commit-gate redesign (#2723 split: dispatch only):
#   - hooks/workflow-gate.js: merge gate + worktree commit skip for user_verification
#   - hooks/workflow-mark.js: feature-branch push does not reset user_verification
#   - bin/review-code-codex: staged diff fallback when there are no commits past base
# Shared helpers: feature-commit-gate-redesign/_lib.sh; one file per section: section-a.sh .. section-f.sh.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CGR_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-commit-gate-redesign"

source "$CGR_DIR/_lib.sh"
source "$CGR_DIR/section-a.sh"
source "$CGR_DIR/section-b.sh"
source "$CGR_DIR/section-c.sh"
source "$CGR_DIR/section-d.sh"
source "$CGR_DIR/section-e.sh"
source "$CGR_DIR/section-f.sh"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
