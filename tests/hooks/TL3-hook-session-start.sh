#!/usr/bin/env bash
# Tests: hooks/session-start.js
# Tags: session-start, hook, TL3, run-e2e, scope:common
#
# Issue #943 — per-hook seam TL3 test: session-start.js (SessionStart).
# Fresh `claude -p` session with no prior state → createInitialState writes a
# state file with all steps pending, and additionalContext surfaces the sid.
# Layer: TL3 (live claude -p session, real SessionStart firing, real state file).
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

[ -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ] || exit 77
"$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off && exit 77
command -v claude >/dev/null 2>&1 || exit 77

ERRORS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }

# shellcheck source=tests/hooks/TL3-hook-session-start/helpers.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/TL3-hook-session-start/helpers.sh"
# shellcheck source=tests/hooks/TL3-hook-session-start/main.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/TL3-hook-session-start/main.sh"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
