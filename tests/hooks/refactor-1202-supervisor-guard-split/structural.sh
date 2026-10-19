#!/bin/bash
# tests/hooks/refactor-1202-supervisor-guard-split/structural.sh
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _SCRIPT_CHECKOUT_ROOT_NODE="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"
else
    _SCRIPT_CHECKOUT_ROOT_NODE="$SCRIPT_CHECKOUT_ROOT"
fi

GUARD_JS="${_SCRIPT_CHECKOUT_ROOT_NODE}/hooks/supervisor-guard.js"
DETECT_JS="${_SCRIPT_CHECKOUT_ROOT_NODE}/hooks/supervisor-guard/detect.js"
DETECT_PATH="${SCRIPT_CHECKOUT_ROOT}/hooks/supervisor-guard/detect.js"
GUARD_PATH="${SCRIPT_CHECKOUT_ROOT}/hooks/supervisor-guard.js"
# #2698: the AskUserQuestion turn judgment moved from detect.js into the shared predicate.
UDT_JS="${_SCRIPT_CHECKOUT_ROOT_NODE}/hooks/lib/user-dialog-turn.js"

if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not on PATH"
    exit 0
fi

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# ─── POST-REFACTOR CONTRACT TESTS ────────────────────────────────────────────

# 1. hooks/supervisor-guard/detect.js file exists
if [ -f "$DETECT_PATH" ]; then
    pass "hooks/supervisor-guard/detect.js file exists"
else
    skip "hooks/supervisor-guard/detect.js file exists (not implemented yet)"
fi

# 2. detect.js exports detectSentinelHang as a function
if [ ! -f "$DETECT_PATH" ]; then
    skip "detectSentinelHang exported (detect.js missing)"
else
    out=$(run_with_timeout 10 node -e "
const m = require('${DETECT_JS}');
if (typeof m.detectSentinelHang !== 'function') {
  console.log('FAIL: detectSentinelHang is ' + typeof m.detectSentinelHang);
  process.exit(1);
}
console.log('OK');
" 2>&1)
    if [ "$out" = "OK" ]; then
        pass "require('./supervisor-guard/detect') exports detectSentinelHang as a function"
    else
        fail "require('./supervisor-guard/detect') exports detectSentinelHang as a function" "$out"
    fi
fi

# 3. #2698: detect.js no longer exports detectAskUserQuestionTurn; the shared predicate
#    hooks/lib/user-dialog-turn.js exports isUserDialogTurn / classifyUserDialogTurn instead.
if [ ! -f "$DETECT_PATH" ]; then
    skip "detectAskUserQuestionTurn moved to user-dialog-turn.js (detect.js missing)"
else
    out=$(run_with_timeout 10 node -e "
const m = require('${DETECT_JS}');
if ('detectAskUserQuestionTurn' in m) {
  console.log('FAIL: detect.js still exports detectAskUserQuestionTurn');
  process.exit(1);
}
let u;
try { u = require('${UDT_JS}'); } catch (e) { console.log('FAIL: user-dialog-turn.js does not load: ' + e.message); process.exit(1); }
for (const k of ['isUserDialogTurn', 'classifyUserDialogTurn']) {
  if (typeof u[k] !== 'function') { console.log('FAIL: ' + k + ' is ' + typeof u[k]); process.exit(1); }
}
console.log('OK');
" 2>&1)
    if [ "$out" = "OK" ]; then
        pass "detectAskUserQuestionTurn moved: detect.js drops it, user-dialog-turn.js exports isUserDialogTurn/classifyUserDialogTurn"
    else
        fail "detectAskUserQuestionTurn moved: detect.js drops it, user-dialog-turn.js exports isUserDialogTurn/classifyUserDialogTurn" "$out"
    fi
fi

# 4. detect.js exports parseTranscriptForAudit as a function
if [ ! -f "$DETECT_PATH" ]; then
    skip "parseTranscriptForAudit exported (detect.js missing)"
else
    out=$(run_with_timeout 10 node -e "
const m = require('${DETECT_JS}');
if (typeof m.parseTranscriptForAudit !== 'function') {
  console.log('FAIL: parseTranscriptForAudit is ' + typeof m.parseTranscriptForAudit);
  process.exit(1);
}
console.log('OK');
" 2>&1)
    if [ "$out" = "OK" ]; then
        pass "detect.js exports parseTranscriptForAudit as a function"
    else
        fail "detect.js exports parseTranscriptForAudit as a function" "$out"
    fi
fi

# 5. detect.js exports detectOffProposal as a function
if [ ! -f "$DETECT_PATH" ]; then
    skip "detectOffProposal exported (detect.js missing)"
else
    out=$(run_with_timeout 10 node -e "
const m = require('${DETECT_JS}');
if (typeof m.detectOffProposal !== 'function') {
  console.log('FAIL: detectOffProposal is ' + typeof m.detectOffProposal);
  process.exit(1);
}
console.log('OK');
" 2>&1)
    if [ "$out" = "OK" ]; then
        pass "detect.js exports detectOffProposal as a function"
    else
        fail "detect.js exports detectOffProposal as a function" "$out"
    fi
fi

# 6. detectSentinelHang: empty transcript → false; non-existent file → false (fail-open)
if [ ! -f "$DETECT_PATH" ]; then
    skip "detectSentinelHang smoke + fail-open (detect.js missing)"
else
    _tmp_t=$(mktemp)
    out=$(run_with_timeout 10 node -e "
const m = require('${DETECT_JS}');
const r1 = m.detectSentinelHang('${_tmp_t}');
if (r1 !== false) { console.log('FAIL: empty transcript returned ' + r1); process.exit(1); }
const r2 = m.detectSentinelHang('/nonexistent-file-12345');
if (r2 !== false) { console.log('FAIL: nonexistent returned ' + r2); process.exit(1); }
console.log('OK');
" 2>&1)
    rm -f "$_tmp_t"
    if [ "$out" = "OK" ]; then pass "detectSentinelHang: empty→false, nonexistent→false (fail-open)"
    else fail "detectSentinelHang: empty→false, nonexistent→false" "$out"; fi
fi

# 7. detectOffProposal: empty transcript → {detected:false}; non-existent → {detected:false}
if [ ! -f "$DETECT_PATH" ]; then
    skip "detectOffProposal smoke + fail-open (detect.js missing)"
else
    _tmp_t2=$(mktemp)
    out=$(run_with_timeout 10 node -e "
const m = require('${DETECT_JS}');
const r1 = m.detectOffProposal('${_tmp_t2}');
if (!r1 || r1.detected !== false) { console.log('FAIL: empty transcript returned ' + JSON.stringify(r1)); process.exit(1); }
const r2 = m.detectOffProposal('/nonexistent-file-12345');
if (!r2 || r2.detected !== false) { console.log('FAIL: nonexistent returned ' + JSON.stringify(r2)); process.exit(1); }
console.log('OK');
" 2>&1)
    rm -f "$_tmp_t2"
    if [ "$out" = "OK" ]; then pass "detectOffProposal: empty→{detected:false}, nonexistent→{detected:false} (fail-open)"
    else fail "detectOffProposal: empty→{detected:false}, nonexistent→{detected:false}" "$out"; fi
fi

# 8. hooks/supervisor-guard.js does NOT contain inline `function detectSentinelHang` definition
if [ ! -f "$GUARD_PATH" ]; then
    skip "hooks/supervisor-guard.js structural check (file missing)"
else
    if grep -q "^function detectSentinelHang" "$GUARD_PATH"; then
        fail "hooks/supervisor-guard.js does NOT contain inline function detectSentinelHang definition" \
            "inline definition found — function should live in hooks/supervisor-guard/detect.js"
    else
        pass "hooks/supervisor-guard.js does NOT contain inline function detectSentinelHang definition"
    fi
fi

# 9. hooks/supervisor-guard.js contains a require to ./supervisor-guard/detect
if [ ! -f "$GUARD_PATH" ]; then
    skip "hooks/supervisor-guard.js require check (file missing)"
else
    if grep -q "require.*supervisor-guard/detect" "$GUARD_PATH"; then
        pass "hooks/supervisor-guard.js contains require('./supervisor-guard/detect')"
    else
        fail "hooks/supervisor-guard.js contains require('./supervisor-guard/detect')" \
            "require not found — dispatch file must load the detect module"
    fi
fi

# 10. isUserDialogTurn (the moved AskUserQuestion judgment): empty transcript → false;
#     non-existent → false (fail-open)
_tmp_t3=$(mktemp)
_tmp_t3_node="$_tmp_t3"
if command -v cygpath >/dev/null 2>&1; then _tmp_t3_node="$(cygpath -m "$_tmp_t3")"; fi
out=$(run_with_timeout 10 node -e "
const m = require('${UDT_JS}');
const r1 = m.isUserDialogTurn({ transcript_path: '${_tmp_t3_node}', last_assistant_message: '' });
if (r1 !== false) { console.log('FAIL: empty transcript returned ' + r1); process.exit(1); }
const r2 = m.isUserDialogTurn({ transcript_path: '/nonexistent-file-12345', last_assistant_message: '' });
if (r2 !== false) { console.log('FAIL: nonexistent returned ' + r2); process.exit(1); }
console.log('OK');
" 2>&1)
rm -f "$_tmp_t3"
if [ "$out" = "OK" ]; then pass "isUserDialogTurn: empty→false, nonexistent→false (fail-open)"
else fail "isUserDialogTurn: empty→false, nonexistent→false" "$out"; fi

# 11. parseTranscriptForAudit: empty transcript → []; non-existent → [] (fail-open)
if [ ! -f "$DETECT_PATH" ]; then
    skip "parseTranscriptForAudit smoke + fail-open (detect.js missing)"
else
    _tmp_t4=$(mktemp)
    out=$(run_with_timeout 10 node -e "
const m = require('${DETECT_JS}');
const r1 = m.parseTranscriptForAudit('${_tmp_t4}');
if (!Array.isArray(r1) || r1.length !== 0) { console.log('FAIL: empty transcript returned ' + JSON.stringify(r1)); process.exit(1); }
const r2 = m.parseTranscriptForAudit('/nonexistent-file-12345');
if (!Array.isArray(r2) || r2.length !== 0) { console.log('FAIL: nonexistent returned ' + JSON.stringify(r2)); process.exit(1); }
console.log('OK');
" 2>&1)
    rm -f "$_tmp_t4"
    if [ "$out" = "OK" ]; then pass "parseTranscriptForAudit: empty→[], nonexistent→[] (fail-open)"
    else fail "parseTranscriptForAudit: empty→[], nonexistent→[]" "$out"; fi
fi

# 12. dispatch integration smoke: require supervisor-guard.js loads without error when detect.js exists
if [ ! -f "$DETECT_PATH" ]; then
    skip "dispatch integration smoke (detect.js missing)"
else
    out=$(run_with_timeout 10 node -e "
try {
  require('${GUARD_JS}');
  console.log('OK');
} catch (e) {
  console.log('FAIL: require supervisor-guard.js threw ' + e.message);
  process.exit(1);
}
" 2>&1)
    if [ "$out" = "OK" ]; then
        pass "require(supervisor-guard.js) loads without error (dispatch + detect integration)"
    else
        fail "require(supervisor-guard.js) loads without error (dispatch + detect integration)" "$out"
    fi
fi

# 13-14. hooks/supervisor-guard.js does NOT contain inline definitions of the other detect.js
#        functions (#2698 moved detectAskUserQuestionTurn out of detect.js entirely)
for fn in parseTranscriptForAudit detectOffProposal; do
    if [ ! -f "$GUARD_PATH" ]; then
        skip "structural: no inline $fn (guard file missing)"
    elif grep -q "^function $fn" "$GUARD_PATH"; then
        fail "hooks/supervisor-guard.js does NOT contain inline function $fn" \
            "inline definition found — should live in hooks/supervisor-guard/detect.js"
    else
        pass "hooks/supervisor-guard.js does NOT contain inline function $fn"
    fi
done

# ─── SUMMARY ─────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
