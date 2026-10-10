#!/usr/bin/env bash
# Tests: hooks/lib/command-parser.js, hooks/lib/command-ir.js, hooks/lib/bash-write-targets/helpers.js, hooks/lib/bash-write-targets/redirect.js, hooks/lib/bash-write-targets/tee.js, hooks/lib/bash-write-targets/cp-mv.js, hooks/lib/bash-write-targets/rm.js, hooks/lib/bash-write-targets/pwsh.js, hooks/lib/bash-write-targets.js, hooks/enforce-worktree/bash-write-scope.js
# Tags: ir-extractor, bash-write-targets, quote-context, scope:issue-specific
# mutation-probe: bin/mutation-probe.sh hooks/lib/command-parser.js (tokenizeSegmentWithQuotes)
# L3 gap: live claude -p hook registration/firing of block-*.js on PreToolUse, the full
# enforce-worktree allow-chain, and whether real callers route EVERY segment through
# collectWriteTargetsFromSegments (part1 Sections D/BL cover helper + subprocess only).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
# NEW-API cases FAIL until the IR migration lands; existing-infra cases must PASS now.
# Parts live under feature-1295-ir-extractor/ (feature-1147 dispatcher convention).
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT
SUITE_DIR="$(cd "$(dirname "$0")/feature-1295-ir-extractor" && pwd)"
TOTAL_FAIL=0

run_suite() {
  local script="$1"
  local rc=0
  bash "$SUITE_DIR/$script" "$SCRIPT_CHECKOUT_ROOT" || rc=$?
  # rc 77 == SKIP (node absent); propagate as a skip for the whole suite.
  if [ "$rc" -eq 77 ]; then
    echo "SKIP: $script — node not found"; exit 77
  fi
  TOTAL_FAIL=$((TOTAL_FAIL + rc))
}

echo "--- Suite: parser / IR / expansion / redirect / collector (part1) ---"
run_suite "part1-parser-ir.sh"

echo ""
echo "--- Suite: per-verb extractors + collectBashWriteTargets bridge (part2) ---"
run_suite "part2-extractors.sh"

echo ""
echo "==================================================="
echo "TOTAL FAIL across parts: $TOTAL_FAIL"
echo "  (NEW-API sections exercise the canary-4 IR-extractor migration and are"
echo "   EXPECTED to FAIL until it lands. String-API / parse / expandStaticShellTokens"
echo "   / collectBashWriteTargets-bridge cases are existing infra and must PASS now.)"
echo "==================================================="
[ "$TOTAL_FAIL" -eq 0 ]
