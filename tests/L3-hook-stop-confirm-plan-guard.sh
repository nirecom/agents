#!/usr/bin/env bash
# Tests: hooks/stop-confirm-plan-guard.js
# Tags: stop-confirm-plan-guard, hook, L3, run-e2e, scope:permanent
#
# Issue #943 — per-hook seam L3 test: stop-confirm-plan-guard.js (Stop).
# A per-turn marker fixture is placed in CLAUDE_WORKFLOW_DIR; a live `claude -p`
# session triggers the Stop hook, which reads and deletes the marker via
# readAndDeleteTurnMarkers(). Assert marker present before, absent after.
# Layer: L3 (live claude -p session, real Stop firing, real turn marker).
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

[ -x "$AGENTS_DIR/bin/get-config-var" ] || exit 77
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_E2E off && exit 77
command -v claude >/dev/null 2>&1 || exit 77

ERRORS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }

# shellcheck source=tests/L3-hook-stop-confirm-plan-guard/helpers.sh
. "$AGENTS_DIR/tests/L3-hook-stop-confirm-plan-guard/helpers.sh"
# shellcheck source=tests/L3-hook-stop-confirm-plan-guard/main.sh
. "$AGENTS_DIR/tests/L3-hook-stop-confirm-plan-guard/main.sh"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
