#!/usr/bin/env bash
# Tests: hooks/lib/is-private-repo.js, hooks/lib/parse-git-args.js, hooks/workflow-gate.js
# Tags: workflow, gate, hook, bin, windows, scope:common
# Tests for workflow-gate.js: resolveRepoDir, hasStagedTestChanges, hasStagedDocChanges
# Branch: fix/workflow-gate-unix-path

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_DIR="$SCRIPT_DIR/fix-workflow-gate-unix-path"

# shellcheck source=/dev/null
. "$SUB_DIR/_setup.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-a-path-normalization.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-bc-staged-integration.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-dg-git-command.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-h-worktree-gating.sh"

# ============================================================
# Summary
# ============================================================
echo ""
echo "=============================="
echo "Results: PASS=$PASS FAIL=$FAIL"
if [ "${#ERRORS[@]}" -gt 0 ]; then
  echo "Failed tests:"
  for e in "${ERRORS[@]}"; do
    echo "  - $e"
  done
fi
echo "=============================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
