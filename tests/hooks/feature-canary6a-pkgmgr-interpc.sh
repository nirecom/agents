#!/usr/bin/env bash
# tests/hooks/feature-canary6a-pkgmgr-interpc.sh
# Tests: hooks/lib/bash-write-targets/pkg-mgr.js, hooks/lib/bash-write-targets.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-patterns/classify.js
# Tags: scope:issue-specific, pkg-mgr, interpreter-c, canary-6a, enforce-worktree, classify, ir-migration, hook-registration, pwsh-not-required
# Dispatcher for the canary-6a pkg-mgr (7 tools) + interpreter-c WRITE_PATTERNS → IR migration suite (#1411); one part per axis, split per rules/coding/file-split.md.
# RED-pending: isPkgMgrWriteIR (pkg-mgr.js) / isInterpreterCWriteIR do NOT exist yet; parts guard require()/typeof and FAIL cleanly or SKIP (exit 0).
# pwsh-not-required: pwsh-cmdlet cases drive node classify()/predicates over parsed IR — no real pwsh shell is spawned.
# L3 gap (applies to every L2 case below): real PreToolUse dispatch only fires inside a live `claude -p` session; these L2 cases drive node predicates / enforce-worktree.js over stdin JSON.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight bin/check-verification-gate.sh category: hook-registration.

set -uo pipefail

# isolation (#2512): pin state and plans dirs once here so every part inherits them (lib.sh then pins nothing of its own).
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE="$(cd "$DIR/../.." && pwd)"
PARTS_DIR="$DIR/feature-canary6a-pkgmgr-interpc"

TOTAL_FAIL=0
for part in pkg-mgr-ir interpc-ir scope-pipeline regression-allow-paths; do
  echo "########################################################"
  echo "## $part"
  echo "########################################################"
  bash "$PARTS_DIR/$part.sh" "$WORKTREE"
  rc=$?
  if [ "$rc" -eq 77 ]; then
    echo "SKIP: $part exited 77 (dependency missing)"
  elif [ "$rc" -ne 0 ]; then
    TOTAL_FAIL=$((TOTAL_FAIL + rc))
  fi
done

echo ""
echo "======================================================="
echo "Suite TOTAL_FAIL=$TOTAL_FAIL"
[ "$TOTAL_FAIL" -gt 0 ] && exit 1
exit 0
