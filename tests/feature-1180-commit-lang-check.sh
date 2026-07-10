#!/bin/bash
# tests/feature-1180-commit-lang-check.sh
# Tests: hooks/lib/lint-commit-lang.js, hooks/pre-commit, hooks/lib/lang-config.js
# Tags: lang-enforce, commit-hook, scope:issue-specific
#
# Integration cases invoke hooks/pre-commit directly (per the established
# feature-workflow-off-bypass-pre-commit.sh pattern) rather than a real `git commit`;
# the real-git-wiring gap is already covered by the `# L3 gap` block below.
#
# L3 gap (what this test does NOT catch):
# - Real Windows git-bash pre-commit execution with real `node` PATH + AGENTS_CONFIG_DIR symlink resolution
# - Interaction with the real settings.json effortLevel auto-unstage block ordering
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration
#
# RED phase: CL-U* and language-blocked CL-I* cases expected FAIL until /write-code creates:
#   hooks/lib/lint-commit-lang.js  (new module)
#   hooks/pre-commit               (modified to add unconditional CODE_LANG check block)
#
# Dispatcher: this entry file (invoked by run-all.sh at this exact path) sources
# the shared harness (lib.sh) and each case group under
# tests/feature-1180-commit-lang-check/, in the original case order. It aggregates
# PASS/FAIL and exits non-zero if any case failed. See rules/coding/file-split.md
# (HARD 500-line limit) for why the cases live in sibling files.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1180-commit-lang-check"

# shellcheck source=./feature-1180-commit-lang-check/lib.sh
. "$SCRIPT_DIR/lib.sh"

# shellcheck source=./feature-1180-commit-lang-check/group-u.sh
. "$SCRIPT_DIR/group-u.sh"
# shellcheck source=./feature-1180-commit-lang-check/group-i.sh
. "$SCRIPT_DIR/group-i.sh"
# shellcheck source=./feature-1180-commit-lang-check/group-u-postfix.sh
. "$SCRIPT_DIR/group-u-postfix.sh"
# shellcheck source=./feature-1180-commit-lang-check/group-i-postfix.sh
. "$SCRIPT_DIR/group-i-postfix.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
