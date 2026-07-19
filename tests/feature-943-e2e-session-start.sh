#!/usr/bin/env bash
# Tests: hooks/session-start.js
# Tags: session-start, hook, e2e, run-e2e, scope:issue-specific
#
# Issue #943 — per-hook seam L3 test: session-start.js (SessionStart).
# Fresh `claude -p` session with no prior state → createInitialState writes a
# state file with all steps pending, and additionalContext surfaces the sid.
# Layer: L3 (live claude -p session, real SessionStart firing, real state file).
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

[ -x "$AGENTS_DIR/bin/get-config-var" ] || exit 77
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_E2E off && exit 77
command -v claude >/dev/null 2>&1 || exit 77

ERRORS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }

# shellcheck source=tests/feature-943-e2e-session-start/helpers.sh
. "$AGENTS_DIR/tests/feature-943-e2e-session-start/helpers.sh"
# shellcheck source=tests/feature-943-e2e-session-start/e2e-main.sh
. "$AGENTS_DIR/tests/feature-943-e2e-session-start/e2e-main.sh"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
