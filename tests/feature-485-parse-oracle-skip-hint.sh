#!/bin/bash
# Tests: bin/workflow/lib/parse-oracle-output.js
# Tags: L1, workflow, skip-signal, scope:issue-specific
#
# Issue #485 — parse-oracle-output.js gains an optional SKIP_HINT key.
#   - 4-line input (no SKIP_HINT)  → parsed; SKIP_HINT defaults to ""
#   - 5-line input with SKIP_HINT  → parsed; SKIP_HINT field carries the value
#   - malformed input              → abort object with SKIP_HINT: ""
#
# L3 gap: none — pure parser unit (L1). No environment-specific path exercised.

set -euo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="$AGENTS_DIR/bin/workflow/lib/parse-oracle-output.js"
PARSER="$(cygpath -m "$PARSER" 2>/dev/null || echo "$PARSER")"

[ -f "$AGENTS_DIR/bin/workflow/lib/parse-oracle-output.js" ] || {
  echo "SKIP: parse-oracle-output.js not found"
  exit 0
}

PASS=0
FAIL=0

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc -- expected [$expected] got [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

# Parse a here-stringed oracle stdout and print one parsed field.
# $1 = JS string literal for stdout, $2 = field name.
parse_field() {
  local stdin_js="$1" field="$2"
  run_with_timeout node -e "
    const { parseOracleOutput } = require('$PARSER');
    const r = parseOracleOutput($stdin_js);
    const v = r['$field'];
    console.log(v === undefined ? '<undefined>' : String(v));
  " 2>/dev/null
}

FOUR_LINE="'ACTION=invoke\nNEXT_SKILL=make-outline-plan\nNEXT_HINT=run it\nREASON=outline'"
FIVE_LINE_DETAIL="'ACTION=invoke\nNEXT_SKILL=make-detail-plan\nNEXT_HINT=run it\nREASON=detail\nSKIP_HINT=WORKFLOW_DETAIL_NOT_NEEDED'"
FIVE_LINE_OUTLINE="'ACTION=invoke\nNEXT_SKILL=make-outline-plan\nNEXT_HINT=run it\nREASON=outline\nSKIP_HINT=WORKFLOW_OUTLINE_NOT_NEEDED'"
MALFORMED="'garbage without keys'"
EMPTY="''"

echo ""
echo "=== PO-1: 4-line input parses; ACTION=invoke ==="
check "PO-1a. ACTION=invoke" "invoke" "$(parse_field "$FOUR_LINE" ACTION)"
echo "=== PO-1b: SKIP_HINT defaults to '' on 4-line input ==="
check "PO-1b. SKIP_HINT defaults to ''" "" "$(parse_field "$FOUR_LINE" SKIP_HINT)"

echo ""
echo "=== PO-2: 5-line input → SKIP_HINT=WORKFLOW_DETAIL_NOT_NEEDED ==="
check "PO-2. SKIP_HINT field carries detail value" \
  "WORKFLOW_DETAIL_NOT_NEEDED" "$(parse_field "$FIVE_LINE_DETAIL" SKIP_HINT)"

echo ""
echo "=== PO-3: 5-line input → SKIP_HINT=WORKFLOW_OUTLINE_NOT_NEEDED ==="
check "PO-3. SKIP_HINT field carries outline value" \
  "WORKFLOW_OUTLINE_NOT_NEEDED" "$(parse_field "$FIVE_LINE_OUTLINE" SKIP_HINT)"

echo ""
echo "=== PO-4: malformed input → abort + SKIP_HINT='' ==="
check "PO-4a. ACTION=abort on malformed" "abort" "$(parse_field "$MALFORMED" ACTION)"
check "PO-4b. SKIP_HINT='' on malformed" "" "$(parse_field "$MALFORMED" SKIP_HINT)"

echo ""
echo "=== PO-5: empty input → abort + SKIP_HINT='' ==="
check "PO-5a. ACTION=abort on empty input" "abort" "$(parse_field "$EMPTY" ACTION)"
check "PO-5b. SKIP_HINT='' on empty input" "" "$(parse_field "$EMPTY" SKIP_HINT)"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
