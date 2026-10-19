#!/bin/bash
# tests/hooks/refactor-1202-supervisor-guard-split/edge.sh
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _SCRIPT_CHECKOUT_ROOT_NODE="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"
else
    _SCRIPT_CHECKOUT_ROOT_NODE="$SCRIPT_CHECKOUT_ROOT"
fi

DETECT_JS="${_SCRIPT_CHECKOUT_ROOT_NODE}/hooks/supervisor-guard/detect.js"
DETECT_PATH="${SCRIPT_CHECKOUT_ROOT}/hooks/supervisor-guard/detect.js"
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

# 16. detectSentinelHang: empty string "" → false (falsy transcriptPath early-return)
if [ ! -f "$DETECT_PATH" ]; then
    skip "detectSentinelHang(\"\") early-return (detect.js missing)"
else
    out=$(run_with_timeout 10 node -e "
const m = require('${DETECT_JS}');
const r = m.detectSentinelHang('');
if (r !== false) { console.log('FAIL: empty string returned ' + r); process.exit(1); }
console.log('OK');
" 2>&1)
    if [ "$out" = "OK" ]; then pass "detectSentinelHang(\"\") → false (falsy early-return)"
    else fail "detectSentinelHang(\"\") → false (falsy early-return)" "$out"; fi
fi

# 17. detectOffProposal: empty string "" → {detected:false} (falsy transcriptPath early-return)
if [ ! -f "$DETECT_PATH" ]; then
    skip "detectOffProposal(\"\") early-return (detect.js missing)"
else
    out=$(run_with_timeout 10 node -e "
const m = require('${DETECT_JS}');
const r = m.detectOffProposal('');
if (!r || r.detected !== false) { console.log('FAIL: empty string returned ' + JSON.stringify(r)); process.exit(1); }
console.log('OK');
" 2>&1)
    if [ "$out" = "OK" ]; then pass "detectOffProposal(\"\") → {detected:false} (falsy early-return)"
    else fail "detectOffProposal(\"\") → {detected:false} (falsy early-return)" "$out"; fi
fi

# 18. isUserDialogTurn: transcript_path "" → false (falsy transcriptPath early-return)
out=$(run_with_timeout 10 node -e "
const m = require('${UDT_JS}');
const r = m.isUserDialogTurn({ transcript_path: '', last_assistant_message: '' });
if (r !== false) { console.log('FAIL: empty string returned ' + r); process.exit(1); }
console.log('OK');
" 2>&1)
if [ "$out" = "OK" ]; then pass "isUserDialogTurn({transcript_path:\"\"}) → false (falsy early-return)"
else fail "isUserDialogTurn({transcript_path:\"\"}) → false (falsy early-return)" "$out"; fi

# 19. parseTranscriptForAudit: empty string "" → [] (falsy transcriptPath early-return)
if [ ! -f "$DETECT_PATH" ]; then
    skip "parseTranscriptForAudit(\"\") early-return (detect.js missing)"
else
    out=$(run_with_timeout 10 node -e "
const m = require('${DETECT_JS}');
const r = m.parseTranscriptForAudit('');
if (!Array.isArray(r) || r.length !== 0) { console.log('FAIL: empty string returned ' + JSON.stringify(r)); process.exit(1); }
console.log('OK');
" 2>&1)
    if [ "$out" = "OK" ]; then pass "parseTranscriptForAudit(\"\") → [] (falsy early-return)"
    else fail "parseTranscriptForAudit(\"\") → [] (falsy early-return)" "$out"; fi
fi

# 20. detectSentinelHang(null) → false
if [ ! -f "$DETECT_PATH" ]; then
    skip "detectSentinelHang(null) → false (detect.js missing)"
else
    out=$(run_with_timeout 10 node -e "
const m = require('${DETECT_JS}');
const r = m.detectSentinelHang(null);
if (r !== false) { console.log('FAIL: null returned ' + r); process.exit(1); }
console.log('OK');
" 2>&1)
    if [ "$out" = "OK" ]; then pass "detectSentinelHang(null) → false"
    else fail "detectSentinelHang(null) → false" "$out"; fi
fi

# 21. isUserDialogTurn(null) and a null transcript_path → false
out=$(run_with_timeout 10 node -e "
const m = require('${UDT_JS}');
const r = m.isUserDialogTurn(null);
if (r !== false) { console.log('FAIL: null returned ' + r); process.exit(1); }
const r2 = m.isUserDialogTurn({ transcript_path: null });
if (r2 !== false) { console.log('FAIL: null transcript_path returned ' + r2); process.exit(1); }
console.log('OK');
" 2>&1)
if [ "$out" = "OK" ]; then pass "isUserDialogTurn(null) / {transcript_path:null} → false"
else fail "isUserDialogTurn(null) / {transcript_path:null} → false" "$out"; fi

# 22. parseTranscriptForAudit(null) → []
if [ ! -f "$DETECT_PATH" ]; then
    skip "parseTranscriptForAudit(null) → [] (detect.js missing)"
else
    out=$(run_with_timeout 10 node -e "
const m = require('${DETECT_JS}');
const r = m.parseTranscriptForAudit(null);
if (!Array.isArray(r) || r.length !== 0) { console.log('FAIL: null returned ' + JSON.stringify(r)); process.exit(1); }
console.log('OK');
" 2>&1)
    if [ "$out" = "OK" ]; then pass "parseTranscriptForAudit(null) → []"
    else fail "parseTranscriptForAudit(null) → []" "$out"; fi
fi

# 23. detectOffProposal(null) → {detected:false, kind:null}
if [ ! -f "$DETECT_PATH" ]; then
    skip "detectOffProposal(null) → {detected:false} (detect.js missing)"
else
    out=$(run_with_timeout 10 node -e "
const m = require('${DETECT_JS}');
const r = m.detectOffProposal(null);
if (!r || r.detected !== false) { console.log('FAIL: null returned ' + JSON.stringify(r)); process.exit(1); }
console.log('OK');
" 2>&1)
    if [ "$out" = "OK" ]; then pass "detectOffProposal(null) → {detected:false,kind:null}"
    else fail "detectOffProposal(null) → {detected:false,kind:null}" "$out"; fi
fi

# 24. the 3 detect.js functions + isUserDialogTurn on file with unparseable JSONL → fail-open values
if [ ! -f "$DETECT_PATH" ]; then
    skip "malformed JSONL → fail-open (detect.js missing)"
else
    _tmp_bad=$(mktemp)
    printf '%s\n' 'not-json-garbage' 'more-garbage' > "$_tmp_bad"
    _tmp_bad_node="$_tmp_bad"
    if command -v cygpath >/dev/null 2>&1; then
        _tmp_bad_node="$(cygpath -m "$_tmp_bad")"
    fi
    out=$(run_with_timeout 10 node -e "
const m = require('${DETECT_JS}');
const p = '${_tmp_bad_node}';
const r1 = m.detectSentinelHang(p);
if (r1 !== false) { console.log('FAIL: detectSentinelHang returned ' + r1); process.exit(1); }
let r2;
try { r2 = require('${UDT_JS}').isUserDialogTurn({ transcript_path: p, last_assistant_message: '' }); }
catch (e) { console.log('FAIL: user-dialog-turn.js does not load: ' + e.message); process.exit(1); }
if (r2 !== false) { console.log('FAIL: isUserDialogTurn returned ' + r2); process.exit(1); }
const r3 = m.parseTranscriptForAudit(p);
if (!Array.isArray(r3) || r3.length !== 0) { console.log('FAIL: parseTranscriptForAudit returned ' + JSON.stringify(r3)); process.exit(1); }
const r4 = m.detectOffProposal(p);
if (!r4 || r4.detected !== false) { console.log('FAIL: detectOffProposal returned ' + JSON.stringify(r4)); process.exit(1); }
console.log('OK');
" 2>&1)
    rm -f "$_tmp_bad"
    if [ "$out" = "OK" ]; then pass "malformed JSONL → detect.js functions and isUserDialogTurn return fail-open values"
    else fail "malformed JSONL → detect.js functions and isUserDialogTurn return fail-open values" "$out"; fi
fi

# 40. undefined transcriptPath for detectSentinelHang and detectOffProposal → fail-open
if [ ! -f "$DETECT_PATH" ]; then
    skip "detectSentinelHang(undefined) and detectOffProposal(undefined) → fail-open (detect.js missing)"
else
    out=$(run_with_timeout 10 node -e "
const m = require('${DETECT_JS}');
const r1 = m.detectSentinelHang(undefined);
if (r1 !== false) { console.log('FAIL: detectSentinelHang(undefined) returned ' + r1); process.exit(1); }
const r2 = m.detectOffProposal(undefined);
if (!r2 || r2.detected !== false) { console.log('FAIL: detectOffProposal(undefined) returned ' + JSON.stringify(r2)); process.exit(1); }
console.log('OK');
" 2>&1)
    if [ "$out" = "OK" ]; then pass "detectSentinelHang(undefined)→false and detectOffProposal(undefined)→{detected:false} (fail-open)"
    else fail "detectSentinelHang(undefined)→false and detectOffProposal(undefined)→{detected:false} (fail-open)" "$out"; fi
fi

# ─── SUMMARY ─────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
