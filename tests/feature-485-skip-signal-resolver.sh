#!/bin/bash
# Tests: hooks/lib/workflow-state/skip-signal-resolver.js
# Tags: L2, workflow, skip-signal, scope:issue-specific
#
# Issue #485 — skip-signal-resolver.js: isTrivial predicate.
#
# isTrivial fails to FALSE when uncertain (fail-open toward full workflow).
#
# L3 gap (what this test does NOT catch):
# - Real-world intent.md parsing in a live session where the file is written
#   by an orchestrator mid-workflow (this test uses synthetic intent files).
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -euo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$AGENTS_DIR/hooks/lib/workflow-state/skip-signal-resolver.js"
RESOLVER="$(cygpath -m "$RESOLVER" 2>/dev/null || echo "$RESOLVER")"

[ -f "$AGENTS_DIR/hooks/lib/workflow-state/skip-signal-resolver.js" ] || {
  echo "SKIP: skip-signal-resolver.js not yet implemented"
  exit 0
}

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$PLANS_DIR"
PLANS_DIR_N="$(cygpath -m "$PLANS_DIR" 2>/dev/null || echo "$PLANS_DIR")"

PASS=0
FAIL=0

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

check_true() {
  local desc="$1" actual="$2"
  if [ "$actual" = "true" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc -- expected true, got [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

check_false() {
  local desc="$1" actual="$2"
  if [ "$actual" = "false" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc -- expected false, got [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

# call isTrivial(sessionId, plansDir)
call_is_trivial() {
  local sid="$1" plansdir="$2"
  run_with_timeout node -e "
    const r = require('$RESOLVER');
    try {
      const v = r.isTrivial('$sid', '$plansdir');
      console.log(v ? 'true' : 'false');
    } catch (e) {
      console.log('ERROR: ' + e.message);
    }
  " 2>/dev/null
}

write_intent() {
  local sid="$1" body="$2"
  printf '%s\n' "$body" > "$PLANS_DIR/${sid}-intent.md"
}

# ==========================================================================
# isTrivial
# ==========================================================================

echo ""
echo "=== IT-1: 'fix typo' without broad/new-API keywords → true ==="
SID="it1-$$"
write_intent "$SID" "Fix typo in the variable name and rename the helper."
OUT=$(call_is_trivial "$SID" "$PLANS_DIR_N")
check_true "IT-1. mechanical keyword 'fix typo' → true" "$OUT"

echo ""
echo "=== IT-2: 'redesign' (broad-change keyword) → false ==="
SID="it2-$$"
write_intent "$SID" "Rename the field, then redesign the parser entirely."
OUT=$(call_is_trivial "$SID" "$PLANS_DIR_N")
check_false "IT-2. broad-change keyword 'redesign' → false" "$OUT"

echo ""
echo "=== IT-3: 'new interface' (new-API surface) → false ==="
SID="it3-$$"
write_intent "$SID" "Extract the function and add a new interface for callers."
OUT=$(call_is_trivial "$SID" "$PLANS_DIR_N")
check_false "IT-3. new-API surface 'new interface' → false" "$OUT"

echo ""
echo "=== IT-4: intent.md missing → false (fail-open) ==="
SID="it4-missing-$$"
OUT=$(call_is_trivial "$SID" "$PLANS_DIR_N")
check_false "IT-4. intent.md missing → false (fail-open)" "$OUT"

echo ""
echo "=== IT-5: invalid sessionId → false ==="
OUT=$(call_is_trivial "../etc/passwd" "$PLANS_DIR_N")
check_false "IT-5. invalid sessionId → false" "$OUT"

echo ""
echo "=== IT-6: each remaining mechanical keyword (no broad/new-API) → true ==="
# IT-1 already covers "fix typo"; exercise the rest of the mechanical set.
IT6_N=0
for kw in "rename" "remove unused" "extract" "move" "typo"; do
  IT6_N=$((IT6_N + 1))
  SID="it6-${IT6_N}-$$"
  write_intent "$SID" "Please ${kw} the helper to keep things tidy."
  OUT=$(call_is_trivial "$SID" "$PLANS_DIR_N")
  check_true "IT-6.${IT6_N}. mechanical keyword '${kw}' → true" "$OUT"
done

# ==========================================================================
# describeSkipSignal
# ==========================================================================

echo ""
echo "=== DS-1: describeSkipSignal('isTrivial') returns non-empty string ==="
OUT=$(run_with_timeout node -e "
  const r = require('$RESOLVER');
  try {
    const v = r.describeSkipSignal('isTrivial');
    if (typeof v === 'string' && v.length > 0) { console.log('OK'); }
    else { console.log('BAD'); }
  } catch (e) { console.log('ERROR: ' + e.message); }
" 2>/dev/null)
if [ "$OUT" = "OK" ]; then
  echo "PASS: DS-1. describeSkipSignal('isTrivial') non-empty string"
  PASS=$((PASS + 1))
else
  echo "FAIL: DS-1. describeSkipSignal('isTrivial') -- got [$OUT]"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
