#!/bin/bash
# tests/feature-929-codex-review-parse.sh
# Tests: hooks/lib/codex-review-parse.js
# Tags: supervisor, em-supervisor, codex-review, parse, unit
# RED for issue #929.
#
# L3 gap (what this test does NOT catch):
# - real supervisor agent invoking the full flow inside a live Claude Code session
# - Codex API network call succeeding end-to-end
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

CP_MODULE="$AGENTS_DIR/hooks/lib/codex-review-parse.js"
CP_NODE="$_AGENTS_DIR_NODE/hooks/lib/codex-review-parse.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_function_exists() {
    local fn="$1" label="$2"
    if [ ! -f "$CP_MODULE" ]; then
        skip "$label (source not implemented yet)"; return 1
    fi
    local probe
    probe=$(run_with_timeout 5 node -e "
const m = require('$CP_NODE');
process.stdout.write(typeof m.$fn === 'function' ? 'yes' : 'no');
" 2>/dev/null)
    if [ "$probe" != "yes" ]; then
        skip "$label ($fn not implemented yet)"; return 1
    fi
    return 0
}

# Helper: invokes parseCodexFindings via node with the input from an env var
# to avoid shell quoting nightmares.
parse_via_env() {
    local input="$1"
    CODEX_INPUT="$input" run_with_timeout 5 node -e "
const m = require('$CP_NODE');
const r = m.parseCodexFindings(process.env.CODEX_INPUT || '');
process.stdout.write(JSON.stringify(r));
" 2>&1
}

run_cp1() {
    require_function_exists "parseCodexFindings" "CP1: valid mix of AGREE+DISAGREE → ok, items" || return
    local input out rc
    input='prefix
<!-- begin-codex-output -->
{"idx":0,"verdict":"AGREE","reason":"valid"}
{"idx":1,"verdict":"DISAGREE","reason":"wrong"}
<!-- end-codex-output -->'
    out=$(parse_via_env "$input")
    rc=$?
    # Validate via node
    local check
    check=$(OUT="$out" run_with_timeout 5 node -e "
const r = JSON.parse(process.env.OUT);
if (r.ok !== true) { console.error('not ok'); process.exit(2); }
if (!Array.isArray(r.items) || r.items.length !== 2) { console.error('items len='+(r.items && r.items.length)); process.exit(3); }
if (r.items[0].idx !== 0 || r.items[0].verdict !== 'AGREE') { console.error('item0'); process.exit(4); }
if (r.items[1].idx !== 1 || r.items[1].verdict !== 'DISAGREE') { console.error('item1'); process.exit(5); }
console.log('OK');
" 2>&1)
    if [ $rc -eq 0 ] && [ "$check" = "OK" ]; then
        pass "CP1: valid mix of AGREE+DISAGREE → ok, items"
    else
        fail "CP1: valid mix (rc=$rc, out=$out, check=$check)"
    fi
}

run_cp2() {
    require_function_exists "parseCodexFindings" "CP2: all AGREE" || return
    local input out check
    input='<!-- begin-codex-output -->
{"idx":0,"verdict":"AGREE","reason":"r1"}
{"idx":1,"verdict":"AGREE","reason":"r2"}
<!-- end-codex-output -->'
    out=$(parse_via_env "$input")
    check=$(OUT="$out" run_with_timeout 5 node -e "
const r = JSON.parse(process.env.OUT);
if (r.ok !== true || !Array.isArray(r.items)) process.exit(2);
if (!r.items.every(x => x.verdict === 'AGREE')) process.exit(3);
console.log('OK');
" 2>&1)
    if [ "$check" = "OK" ]; then pass "CP2: all AGREE"
    else fail "CP2: all AGREE (out=$out, check=$check)"; fi
}

run_cp3() {
    require_function_exists "parseCodexFindings" "CP3: all DISAGREE" || return
    local input out check
    input='<!-- begin-codex-output -->
{"idx":0,"verdict":"DISAGREE","reason":"r1"}
{"idx":1,"verdict":"DISAGREE","reason":"r2"}
<!-- end-codex-output -->'
    out=$(parse_via_env "$input")
    check=$(OUT="$out" run_with_timeout 5 node -e "
const r = JSON.parse(process.env.OUT);
if (r.ok !== true) process.exit(2);
if (!r.items.every(x => x.verdict === 'DISAGREE')) process.exit(3);
console.log('OK');
" 2>&1)
    if [ "$check" = "OK" ]; then pass "CP3: all DISAGREE"
    else fail "CP3: all DISAGREE (out=$out, check=$check)"; fi
}

run_cp4() {
    require_function_exists "parseCodexFindings" "CP4: empty content between valid markers → ok:true, items:[]" || return
    local input out check
    input='<!-- begin-codex-output -->
<!-- end-codex-output -->'
    out=$(parse_via_env "$input")
    check=$(OUT="$out" run_with_timeout 5 node -e "
const r = JSON.parse(process.env.OUT);
if (r.ok !== true) process.exit(2);
if (!Array.isArray(r.items) || r.items.length !== 0) process.exit(3);
console.log('OK');
" 2>&1)
    if [ "$check" = "OK" ]; then pass "CP4: empty content between valid markers → ok:true, items:[]"
    else fail "CP4: empty markers (out=$out, check=$check)"; fi
}

run_cp5() {
    require_function_exists "parseCodexFindings" "CP5: output without markers → ok:false" || return
    local out check
    out=$(parse_via_env 'no markers here just some random text')
    check=$(OUT="$out" run_with_timeout 5 node -e "
const r = JSON.parse(process.env.OUT);
if (r.ok !== false) process.exit(2);
console.log('OK');
" 2>&1)
    if [ "$check" = "OK" ]; then pass "CP5: output without markers → ok:false"
    else fail "CP5: missing markers (out=$out, check=$check)"; fi
}

run_cp6() {
    require_function_exists "parseCodexFindings" "CP6: malformed JSON inside markers → ok:false" || return
    local input out check
    input='<!-- begin-codex-output -->
{not valid json at all
<!-- end-codex-output -->'
    out=$(parse_via_env "$input")
    check=$(OUT="$out" run_with_timeout 5 node -e "
const r = JSON.parse(process.env.OUT);
if (r.ok !== false) process.exit(2);
console.log('OK');
" 2>&1)
    if [ "$check" = "OK" ]; then pass "CP6: malformed JSON → ok:false"
    else fail "CP6: malformed JSON (out=$out, check=$check)"; fi
}

run_cp7() {
    require_function_exists "parseCodexFindings" "CP7: missing verdict field → ok:false or warning" || return
    local input out check
    input='<!-- begin-codex-output -->
{"idx":0,"reason":"no verdict"}
<!-- end-codex-output -->'
    out=$(parse_via_env "$input")
    check=$(OUT="$out" run_with_timeout 5 node -e "
const r = JSON.parse(process.env.OUT);
// Accept either ok:false OR ok:true with a warning recorded
const hasWarning = Array.isArray(r.warnings) && r.warnings.length > 0;
const item = (r.items && r.items[0]) || null;
const itemHasWarning = item && (item.warning || (Array.isArray(item.warnings) && item.warnings.length > 0));
if (r.ok === false || hasWarning || itemHasWarning) { console.log('OK'); process.exit(0); }
console.error('neither ok:false nor warning recorded: '+JSON.stringify(r));
process.exit(2);
" 2>&1)
    if [ "$check" = "OK" ]; then pass "CP7: missing verdict → ok:false or warning"
    else fail "CP7: missing verdict (out=$out, check=$check)"; fi
}

run_cp8() {
    require_function_exists "parseCodexFindings" "CP8: invalid verdict value → ok:false or warning" || return
    local input out check
    input='<!-- begin-codex-output -->
{"idx":0,"verdict":"MAYBE","reason":"unsure"}
<!-- end-codex-output -->'
    out=$(parse_via_env "$input")
    check=$(OUT="$out" run_with_timeout 5 node -e "
const r = JSON.parse(process.env.OUT);
const hasWarning = Array.isArray(r.warnings) && r.warnings.length > 0;
const item = (r.items && r.items[0]) || null;
const itemHasWarning = item && (item.warning || (Array.isArray(item.warnings) && item.warnings.length > 0));
if (r.ok === false || hasWarning || itemHasWarning) { console.log('OK'); process.exit(0); }
console.error('neither ok:false nor warning recorded: '+JSON.stringify(r));
process.exit(2);
" 2>&1)
    if [ "$check" = "OK" ]; then pass "CP8: invalid verdict → ok:false or warning"
    else fail "CP8: invalid verdict (out=$out, check=$check)"; fi
}

run_cp9() {
    require_function_exists "parseCodexFindings" "CP9: reason with HTML/shell metachars stored safely" || return
    local input out check
    input='<!-- begin-codex-output -->
{"idx":0,"verdict":"DISAGREE","reason":"contains </script> and `rm -rf /` and $(whoami)"}
<!-- end-codex-output -->'
    out=$(parse_via_env "$input")
    check=$(OUT="$out" run_with_timeout 5 node -e "
const r = JSON.parse(process.env.OUT);
if (r.ok !== true) { console.error('not ok'); process.exit(2); }
const item = r.items[0];
if (!item || !item.reason) { console.error('no reason'); process.exit(3); }
if (!item.reason.includes('</script>')) { console.error('script stripped'); process.exit(4); }
if (!item.reason.includes('rm -rf')) { console.error('shell stripped'); process.exit(5); }
if (!item.reason.includes('whoami')) { console.error('whoami stripped'); process.exit(6); }
console.log('OK');
" 2>&1)
    if [ "$check" = "OK" ]; then pass "CP9: reason with metachars stored safely"
    else fail "CP9: security metachars (out=$out, check=$check)"; fi
}

run_cp10() {
    require_function_exists "parseCodexFindings" "CP10: content outside markers is ignored" || return
    local input out check
    input='garbage before {"idx":99,"verdict":"NOPE"} more garbage
<!-- begin-codex-output -->
{"idx":0,"verdict":"AGREE","reason":"r"}
<!-- end-codex-output -->
garbage after {"idx":98,"verdict":"NOPE"}'
    out=$(parse_via_env "$input")
    check=$(OUT="$out" run_with_timeout 5 node -e "
const r = JSON.parse(process.env.OUT);
if (r.ok !== true) process.exit(2);
if (r.items.length !== 1) { console.error('len='+r.items.length); process.exit(3); }
if (r.items[0].idx !== 0) { console.error('idx='+r.items[0].idx); process.exit(4); }
console.log('OK');
" 2>&1)
    if [ "$check" = "OK" ]; then pass "CP10: content outside markers ignored"
    else fail "CP10: outside markers (out=$out, check=$check)"; fi
}

run_cp1
run_cp2
run_cp3
run_cp4
run_cp5
run_cp6
run_cp7
run_cp8
run_cp9
run_cp10

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
