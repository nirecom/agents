#!/usr/bin/env bash
# Tests: hooks/lib/command-parser.js, hooks/lib/command-ir.js, hooks/lib/bash-write-targets/helpers.js, hooks/lib/bash-write-targets/redirect.js, hooks/lib/bash-write-targets/tee.js, hooks/lib/bash-write-targets/cp-mv.js, hooks/lib/bash-write-targets/rm.js, hooks/lib/bash-write-targets/pwsh.js, hooks/lib/bash-write-targets.js, hooks/enforce-worktree/bash-write-scope.js
# Tags: ir-extractor, bash-write-targets, quote-context, scope:issue-specific
# mutation-probe: bin/mutation-probe.sh hooks/lib/command-parser.js (tokenizeSegmentWithQuotes)
# L3 gap: real claude -p session with live file writes not tested (cost-prohibitive; L2 covers contract)
# L3 gap (what this test does NOT catch):
# - Real hook registration and firing in a live claude session (block-shell-config.js / block-memory-direct.js / block-history-direct.js wired to PreToolUse)
# - Behavioral change when a command flows through the full enforce-worktree allow-chain into collectBashWriteTargets
# - L2 caller coverage (part1 Section BL) spawns each block-*.js as a subprocess with a
#   PreToolUse event on stdin and asserts its block/approve decision end-to-end; it does
#   NOT reproduce the live session's PreToolUse dispatch or the enforce-worktree allow-chain.
# - Whether the real callers route EVERY pipeline segment through collectWriteTargetsFromSegments
#   post-migration (Section D validates the helper in isolation; Section BL pins current
#   caller block/approve behavior as a migration regression guard — neither proves the
#   post-migration wiring calls the new helper).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
#
# Pre-implementation (WF-CODE-4 / write-tests): the NEW APIs under test do NOT
# exist yet. Cases for NEW functions (tokenizeSegmentWithQuotes, IR additive
# fields argvRaw/cmd0Raw/redirects[].targetRaw, expandRawToken,
# collectWriteTargetsFromSegments, FULL_VERB_SET, SHELL_CONFIG_VERB_SET, and the
# IR-accepting extractor forms) are EXPECTED TO FAIL until the migration lands.
# Cases for existing infrastructure (string-API extractors, parse,
# collectBashWriteTargets string bridge, expandStaticShellTokens) are expected to
# PASS now and must keep passing post-migration (blast-radius-zero / additive-safe pins).
#
# Split (file-split.md HARD limit >500): part suites live under
# feature-1295-ir-extractor/. This dispatcher passes $AGENTS_DIR to each part
# and sums their FAIL counts (feature-1147 dispatcher convention).
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUITE_DIR="$(cd "$(dirname "$0")/feature-1295-ir-extractor" && pwd)"
TOTAL_FAIL=0

run_suite() {
  local script="$1"
  local rc=0
  bash "$SUITE_DIR/$script" "$AGENTS_DIR" || rc=$?
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
