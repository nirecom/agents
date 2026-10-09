#!/usr/bin/env bash
# tests/bin/feature-2434-control-migration.sh
# Tests: hooks/lib/temporary-migrations/control-dir-split/index.js
# Tags: TL2, scope:issue-specific, control-dir, migration
# TL3 gap (what this test does NOT catch):
# - Real filesystem permission errors on production hosts (Windows ACL vs POSIX chmod differ)
# - Actual session-start hook firing in a live Claude Code host
# - Cross-process race conditions between real concurrent sessions
# - mtime semantics on network filesystems (NFS/SMB)
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: migration

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
SUBDIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2434-control-migration"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

RC_ALL=0
FAILED=""

for part in basic conflict-race fault rewrite gating session-start; do
  echo "########## $part ##########"
  bash "$SUBDIR/$part.sh"
  rc=$?
  if [ "$rc" -eq 77 ]; then
    echo "SKIPPED: $part"
  elif [ "$rc" -ne 0 ]; then
    RC_ALL=1
    FAILED="$FAILED $part"
  fi
  echo ""
done

echo "########## feature-2434-control-migration summary ##########"
if [ "$RC_ALL" -eq 0 ]; then
  echo "All parts passed."
else
  echo "Failed parts:$FAILED"
fi
exit "$RC_ALL"
