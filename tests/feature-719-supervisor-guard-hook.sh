#!/bin/bash
# tests/feature-719-supervisor-guard-hook.sh
# Tests: hooks/supervisor-guard.js (Stop hook — wakeup reader / block-on-error)
# Tags: supervisor, em-supervisor, hook, layer2, stop
# RED for issue #719.
# L3 gap (what this test does NOT catch):
# - hook registration in settings.json Stop hooks — if supervisor-guard.js is not wired,
#   L2 sentinel-hang and escape-hatch detection are fully absent but these tests still pass
#   because they invoke the hook script directly
# - real Claude Code transcript format differences — tests use minimal crafted JSONL;
#   live session transcripts may have additional fields or a different JSONL structure
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh
#   fires at WORKFLOW_USER_VERIFIED preflight when settings.json changes are staged

set -u

source "$(dirname "${BASH_SOURCE[0]}")/feature-719-supervisor-guard-hook/_lib.sh"

source "$(dirname "${BASH_SOURCE[0]}")/feature-719-supervisor-guard-hook/g1-g19.sh"
run_g1; run_g2; run_g3; run_g4; run_g5; run_g6; run_g7; run_g8; run_g9; run_g10
run_g11; run_g12; run_g13; run_g14; run_g15; run_g16; run_g17; run_g18; run_g19

source "$(dirname "${BASH_SOURCE[0]}")/feature-719-supervisor-guard-hook/g-c3.sh"
run_g_c3a; run_g_c3b; run_g_c3c

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
