#!/usr/bin/env bash
# Tests: hooks/instructions-loaded-audit.js, hooks/lib/instructions-loaded-receipt.js, hooks/lib/rules-injection-policy.js
# Tags: rules-injection, hook, TL3, run-e2e, scope:common
#
# Observation gate for the reserved-glob off-switch (detail plan section 4).
# Two live `claude -p` runs over an identical fixture rules tree — RUN-BASE proves the
# path is injected at all, RUN-JUDGE proves the reserved glob stops it — with the Q1/Q2/Q3
# quiescence conditions in between so that "absent" cannot mean "not yet arrived".
# Layer: TL3 (live claude -p sessions, real InstructionsLoaded firing, real receipt files).
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Implementation guard runs BEFORE the skip gates: a missing hook is a real defect at any
# RUN_TL3 setting, and exiting 77 for it would disguise the defect as an intentional skip.
IMPL_MISSING=0
for f in "$AGENTS_DIR/hooks/instructions-loaded-audit.js" \
         "$AGENTS_DIR/hooks/lib/instructions-loaded-receipt.js" \
         "$AGENTS_DIR/hooks/lib/rules-injection-policy.js" \
         "$AGENTS_DIR/bin/run-with-timeout.sh"; do
    [ -f "$f" ] || { echo "FAIL: IMPLEMENTATION MISSING: $f"; IMPL_MISSING=1; }
done
if [ "$IMPL_MISSING" -eq 1 ]; then
    echo ""
    echo "1 test(s) failed (targets not yet implemented — detail plan S2-2 / S2-4)"
    exit 1
fi

[ -x "$AGENTS_DIR/bin/get-config-var" ] || exit 77
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off && exit 77
command -v claude >/dev/null 2>&1 || exit 77

ERRORS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }

# shellcheck source=tests/TL3-rules-injection-off-switch/helpers.sh
. "$AGENTS_DIR/tests/TL3-rules-injection-off-switch/helpers.sh"
# shellcheck source=tests/TL3-rules-injection-off-switch/main.sh
. "$AGENTS_DIR/tests/TL3-rules-injection-off-switch/main.sh"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
