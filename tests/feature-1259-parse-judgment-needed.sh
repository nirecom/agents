#!/bin/bash
# Tests: bin/workflow/lib/parse-next-step-output.js
# Tags: L1, workflow, judgment-needed, scope:issue-specific
#
# Issue #1259 — parse-next-step-output.js must accept ACTION=judgment_needed.
# No allowlist on ACTION values; judgment_needed parses as a valid (non-empty) ACTION.
# These tests are expected GREEN now (parser already handles any non-empty ACTION).
#
# L3 gap: none — pure parser unit (L1). No environment-specific path exercised.

set -uo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="$AGENTS_DIR/bin/workflow/lib/parse-next-step-output.js"
PARSER="$(cygpath -m "$PARSER" 2>/dev/null || echo "$PARSER")"

[ -f "$AGENTS_DIR/bin/workflow/lib/parse-next-step-output.js" ] || {
  echo "SKIP: parse-next-step-output.js not found"
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

# Parse a JS string literal for stdout and print one parsed field.
parse_field() {
  local stdin_js="$1" field="$2"
  run_with_timeout node -e "
    const { parseNextStepOutput } = require('$PARSER');
    const r = parseNextStepOutput($stdin_js);
    const v = r['$field'];
    console.log(v === undefined ? '<undefined>' : String(v));
  " 2>/dev/null
}

# --- Test fixtures ---
# P1: valid 4-line output with ACTION=judgment_needed
FOUR_LINE_JUDGMENT="'ACTION=judgment_needed\nNEXT_SKILL=make-outline-plan\nNEXT_HINT=Read intent.md and judge whether to skip\nREASON=outline'"

# P2: missing NEXT_SKILL required key → malformed
MISSING_NEXT_SKILL="'ACTION=judgment_needed\nNEXT_HINT=run it\nREASON=outline'"

# P3: empty ACTION value → malformed
EMPTY_ACTION="'ACTION=\nNEXT_SKILL=make-outline-plan\nNEXT_HINT=run it\nREASON=outline'"

# P4: judgment_needed + optional SKIP_HINT line → SKIP_HINT field populated
FIVE_LINE_JUDGMENT="'ACTION=judgment_needed\nNEXT_SKILL=make-detail-plan\nNEXT_HINT=Read outline.md and judge whether to skip\nREASON=detail\nSKIP_HINT=WORKFLOW_DETAIL_NOT_NEEDED'"

echo ""
echo "=== P1: ACTION=judgment_needed parses without malformed ==="
check "P1a. ACTION=judgment_needed" "judgment_needed" "$(parse_field "$FOUR_LINE_JUDGMENT" ACTION)"
check "P1b. NEXT_SKILL populated" "make-outline-plan" "$(parse_field "$FOUR_LINE_JUDGMENT" NEXT_SKILL)"
check "P1c. SKIP_HINT defaults to empty string" "" "$(parse_field "$FOUR_LINE_JUDGMENT" SKIP_HINT)"

echo ""
echo "=== P2: missing NEXT_SKILL → ACTION=abort (malformed) ==="
check "P2. missing required key → abort" "abort" "$(parse_field "$MISSING_NEXT_SKILL" ACTION)"

echo ""
echo "=== P3: empty ACTION value → ACTION=abort (malformed) ==="
check "P3. empty ACTION → abort" "abort" "$(parse_field "$EMPTY_ACTION" ACTION)"

echo ""
echo "=== P4: judgment_needed + SKIP_HINT line → SKIP_HINT populated ==="
check "P4a. ACTION=judgment_needed with SKIP_HINT" "judgment_needed" "$(parse_field "$FIVE_LINE_JUDGMENT" ACTION)"
check "P4b. SKIP_HINT=WORKFLOW_DETAIL_NOT_NEEDED" "WORKFLOW_DETAIL_NOT_NEEDED" "$(parse_field "$FIVE_LINE_JUDGMENT" SKIP_HINT)"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
