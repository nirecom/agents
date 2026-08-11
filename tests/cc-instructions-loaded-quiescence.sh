#!/usr/bin/env bash
# tests/cc-instructions-loaded-quiescence.sh
# Tests: hooks/lib/instructions-loaded-receipt.js
# Tags: rules-injection, instructions-loaded, quiescence, table-driven, late-arrival, error-handling, TL2, scope:common

# TL2 coverage of waitForQuiescence() (detail plan section 4-3): the Q1 completeness barrier and the
# Q2 stability window, driven by an injected clock so the whole file runs well under the 120s test
# budget. Layer: TL2 (real files in a temp dir, no claude -p, no real sleeping). Dispatcher only:
# the scenario driver lives in cc-instructions-loaded-quiescence/driver.sh, cases in the sibling
# cases-*.sh (rules/coding/file-split.md). TL3 gap (not caught here): the real firing skew S of the host's
# asynchronous InstructionsLoaded dispatch, which is what W = clamp(2*S, 5s, 30s) is derived from at TL3;
# and whether a genuinely late target can arrive AFTER every sibling has quiesced on a real host — only
# tests/TL3-rules-injection-off-switch.sh observes that. Mitigated at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

# CONTRACT NOTE — waitForQuiescence(dir, opts) as encoded here:
#   opts.expected          array of file_path strings = EXPECTED_SET - {target}
#   opts.windowSec         Q2 stability window W
#   opts.q1DeadlineSec     Q1 barrier deadline
#   opts.totalDeadlineSec  Q1+Q2 combined deadline
#   opts.pollMs            poll interval
#   opts.now()             injected clock, ms
#   opts.sleep(ms)         injected sleeper (tests advance the clock inside it)
#   returns { status: "OK" | "INCOMPLETE", entries: [...] }

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")/cc-instructions-loaded-quiescence"
RECEIPT_LIB="$AGENTS_DIR/hooks/lib/instructions-loaded-receipt.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

if [ ! -f "$RECEIPT_LIB" ]; then
    echo "FAIL: IMPLEMENTATION MISSING: $RECEIPT_LIB"
    echo ""
    echo "Results: 0 passed, 1 failed (target not yet implemented — detail plan S2-2)"
    exit 1
fi

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

# shellcheck source=./cc-instructions-loaded-quiescence/driver.sh
. "$SCRIPT_DIR/driver.sh"
# shellcheck source=./cc-instructions-loaded-quiescence/cases-window.sh
. "$SCRIPT_DIR/cases-window.sh"
# shellcheck source=./cc-instructions-loaded-quiescence/cases-errors.sh
. "$SCRIPT_DIR/cases-errors.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
