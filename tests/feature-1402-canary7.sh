#!/usr/bin/env bash
# Tests: hooks/lib/bash-write-targets/here.js, hooks/lib/bash-write-targets/encoded.js, hooks/lib/bash-write-targets/file-op.js, hooks/lib/bash-write-patterns/patterns.js
# Tags: scope:issue-specific, canary-7, ir-migration
#
# Dispatcher for the canary-7 IR migration suite (#1402).
# Covers: pwsh-alias retire, here-system QUOTING_ONLY contract, pwsh-encoded IR
# predicate, extended file-op IR predicate + target extractor, patterns.js static
# checks, and PR #1459 regression allow-paths guard.
#
# RED-pending (fail-before-fix): the new modules (here.js, encoded.js, file-op.js)
# and patterns.js changes do NOT exist yet. Part files guard require()/typeof and
# emit "ERROR:no-module" / "ERROR:not-exported" on missing exports so the harness
# records a clean FAIL. When a module is entirely absent, the part gracefully
# reports the expected failure without aborting.
#
# pwsh-not-required: all pwsh-cmdlet cases drive node classify()/predicates over
# parsed IR — no real pwsh shell is spawned.
#
# L3 gap (what this test does NOT catch):
# - Real PreToolUse dispatch through the live Claude Code hook protocol
# - Session-scoped worktree path comparison in a real Claude session
# - isExtendedFileOpWriteIR wired into the full enforce-worktree allow-chain
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE="$(cd "$DIR/.." && pwd)"
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
