#!/usr/bin/env bash
# Tests: hooks/lib/bash-write-targets/here.js, hooks/lib/bash-write-targets/encoded.js, hooks/lib/bash-write-targets/file-op.js, hooks/lib/bash-write-patterns/patterns.js
# Tags: scope:issue-specific, canary-7, ir-migration
# Dispatcher for the canary-7 IR migration suite (#1402): pwsh-alias retire, here-system QUOTING_ONLY, pwsh-encoded IR, extended file-op IR, patterns.js static checks, PR #1459 allow-paths guard.
# RED-pending: here.js / encoded.js / file-op.js do NOT exist yet; parts guard require()/typeof and emit "ERROR:no-module" / "ERROR:not-exported" for a clean FAIL.
# pwsh-not-required: all pwsh-cmdlet cases drive node classify()/predicates over parsed IR — no real pwsh shell is spawned.
# L3 gap (what this test does NOT catch): real PreToolUse dispatch, session-scoped worktree path comparison, and isExtendedFileOpWriteIR in the full enforce-worktree allow-chain.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration

set -uo pipefail

# isolation (#2512): pin state and plans dirs once here so every part inherits them (lib.sh then pins nothing of its own).
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE="$(cd "$DIR/../.." && pwd)"
PARTS_DIR="$DIR/feature-1402-canary7"

TOTAL_FAIL=0
for part in pwsh-alias-ir here-ir encoded-ir file-op-ir patterns-static regression-allow-paths; do
  echo "########################################################"
  echo "## $part"
  echo "########################################################"
  rc=0
  bash "$PARTS_DIR/$part.sh" "$WORKTREE" || rc=$?
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
