#!/usr/bin/env bash
# Tests: hooks/stop-final-report-guard.js
# Tags: stop-final-report-guard, hook, L3, run-e2e, scope:permanent
#
# Issue #943 — per-hook seam L3 test: stop-final-report-guard.js (Stop).
# A live `claude -p` session with the final-report-env fixture present but no
# Final Report heading emitted → Stop hook fires decision:block and claude
# exits non-zero. Deterministic block case only.
# Layer: L3 (live claude -p session, real Stop firing, real env-file fixture).
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

[ -x "$AGENTS_DIR/bin/get-config-var" ] || exit 77
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_E2E off && exit 77
command -v claude >/dev/null 2>&1 || exit 77

ERRORS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }

# shellcheck source=tests/L3-hook-stop-final-report-guard/helpers.sh
. "$AGENTS_DIR/tests/L3-hook-stop-final-report-guard/helpers.sh"
# shellcheck source=tests/L3-hook-stop-final-report-guard/main.sh
. "$AGENTS_DIR/tests/L3-hook-stop-final-report-guard/main.sh"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
