#!/usr/bin/env bash
# tests/feature-canary6a-pkgmgr-interpc.sh
# Tests: hooks/lib/bash-write-targets/pkg-mgr.js, hooks/lib/bash-write-targets.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-patterns/classify.js
# Tags: scope:issue-specific, pkg-mgr, interpreter-c, canary-6a, enforce-worktree, classify, ir-migration, hook-registration, pwsh-not-required
#
# Dispatcher for the pkg-mgr (7 tools) + interpreter-c WRITE_PATTERNS → IR
# migration suite (#1411, canary-6a). Runs three part files, one per axis
# (pkg-mgr IR predicate, interpreter-c IR predicate, and the scope pipeline +
# PR #1459 allow-path regression guard). Combined the parts exceed 300 lines, so
# they are split per rules/coding/file-split.md.
#
# RED-pending (fail-before-fix): isPkgMgrWriteIR (new module
# hooks/lib/bash-write-targets/pkg-mgr.js) and isInterpreterCWriteIR (new export
# in hooks/lib/bash-write-targets.js) do NOT exist yet. The part files guard
# require()/typeof and either FAIL cleanly (predicate assertions) or SKIP (exit 0)
# when the module is entirely absent, so the dispatcher never aborts mid-run.
#
# pwsh-not-required: the pwsh-cmdlet cases (pwsh -Command Remove-Item) drive
# node classify()/predicates over parsed IR — no real pwsh shell is spawned.
#
# L3 gap (applies to every L2 case below): real PreToolUse dispatch only fires
# inside a live `claude -p` session via the Anthropic hook protocol. These L2
# cases drive node predicates / enforce-worktree.js over stdin JSON, not the real
# hook dispatch. Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight
# bin/check-verification-gate.sh category: hook-registration.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE="$(cd "$DIR/.." && pwd)"
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
