#!/usr/bin/env bash
# Tests: hooks/block-capture-echo.js, hooks/block-capture-echo/shape.js, hooks/block-capture-echo/remedy.js, hooks/preuse-auto-approve.js, hooks/preuse-auto-approve/scratchpad-script.js, hooks/lib/claude-scratchpad-base.js, hooks/lib/command-ir.js, hooks/lib/tool-command-text.js, settings.json, install/settings-allow-commands.txt
# Tags: capture-echo-guard, issuance-discipline, pretooluse, shape-predicate, scratchpad-allow, symlink-traversal, hook-registration, scope:issue-specific, pwsh-not-required
# Dispatcher for the #2170 capture-echo guard suite; parts live under
# tests/feature-2170-capture-echo-guard/ (rules/coding/file-split.md Pattern A).
# TL3 gap (what this test does NOT catch):
# - Live PreToolUse dispatch: part2 spawns the hook as a subprocess and part5 checks
#   settings.json statically; neither observes the hook actually firing in a session.
# - Real auto-approve UX (prompt suppression), and real Windows junction / reparse
#   behavior beyond fs.symlinkSync (part4 D-5 skips per-case when symlinks are denied).

set -uo pipefail

# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
# Pre-implementation status: block-capture-echo.js, block-capture-echo/shape.js,
# block-capture-echo/remedy.js, preuse-auto-approve/scratchpad-script.js and the new
# getCurrentSessionScratchpadRootNorm() export DO NOT EXIST YET; cases targeting them
# must fail with the literal token MODULE_MISSING / HOOK_MISSING / EXPORT_MISSING.
# Any OTHER failure text is a test-authoring bug.
# Must PASS now: part4 SP-21, part5 E-3, part5 E-4. Must FAIL now (pre-fix): E-1, E-2.
# Later run_tests must ALSO re-run: refactor-1294 c6-resolve-effective-command.sh plus
# the existing claude-scratchpad-base.js and preuse-auto-approve.js suites.

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUITE_DIR="$(cd "$(dirname "$0")/feature-2170-capture-echo-guard" && pwd)"
TOTAL_FAIL=0

run_suite() {
  local script="$1"
  local rc=0
  bash "$SUITE_DIR/$script" "$AGENTS_DIR" || rc=$?
  if [ "$rc" -eq 77 ]; then
    echo "SKIP: $script — node not found"
    exit 77
  fi
  TOTAL_FAIL=$((TOTAL_FAIL + rc))
}

echo "--- Section A: shape predicate (detectCaptureEcho) ---"
run_suite "part1-shape-predicate.sh"

echo ""
echo "--- Section B: hook process boundary (block-capture-echo.js subprocess) ---"
run_suite "part2-hook-boundary.sh"

echo ""
echo "--- Section C: remedy degradation contract (buildRemedy) ---"
run_suite "part3-remedy.sh"

echo ""
echo "--- Section C2: remedy degradation on an unusable allowlist file ---"
run_suite "part7-remedy-ssot-edges.sh"

echo ""
echo "--- Section D (D-1..D-4): scratchpad exec-allow judgment ---"
run_suite "part4-scratchpad.sh"

echo ""
echo "--- Section D-5: symlink traversal containment ---"
run_suite "part5-symlink.sh"

echo ""
echo "--- Section E: settings.json consistency ---"
run_suite "part6-settings.sh"

echo ""
echo "--- Section F: separated-argument secret leakage (matched SSOT branch) ---"
run_suite "part8-secret-args.sh"

echo ""
echo "--- Section G: marker non-bypass (.workflow-off / .worktree-off) ---"
run_suite "part9-marker-nonbypass.sh"

echo ""
echo "==================================================="
echo "TOTAL FAIL across parts: $TOTAL_FAIL"
echo "  (Pre-implementation MODULE_MISSING / HOOK_MISSING / EXPORT_MISSING failures"
echo "   are EXPECTED until #2170 lands. See header for the must-pass-now list.)"
echo "==================================================="
[ "$TOTAL_FAIL" -eq 0 ]
