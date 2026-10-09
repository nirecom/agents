#!/usr/bin/env bash
# Tests: hooks/stop-final-report-guard.js
# Tags: stop-final-report-guard, hook, TL3, run-e2e, scope:permanent, scope:issue-specific
#
# Issue #943 — per-hook seam TL3 test: stop-final-report-guard.js (Stop).
# A live `claude -p` session with the final-report-env fixture present but no
# Final Report heading emitted → Stop hook fires decision:block and claude
# exits non-zero. Deterministic block case only.
# Layer: TL3 (live claude -p session, real Stop firing, real env-file fixture).
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

[ -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ] || exit 77
"$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off && exit 77
command -v claude >/dev/null 2>&1 || exit 77

ERRORS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }

# shellcheck source=tests/hooks/TL3-hook-stop-final-report-guard/helpers.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/TL3-hook-stop-final-report-guard/helpers.sh"
# shellcheck source=tests/hooks/TL3-hook-stop-final-report-guard/main.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/TL3-hook-stop-final-report-guard/main.sh"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
