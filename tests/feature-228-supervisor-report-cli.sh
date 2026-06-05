#!/bin/bash
# tests/feature-228-supervisor-report-cli.sh
# Tests: bin/supervisor-report
# Tags: supervisor, em-supervisor, cli, report
# Tests for issue #228 — supervisor-report CLI integration tests.
#
# Verifies bin/supervisor-report writes findings correctly to supervisor-state.json,
# handles multi-category input, deduplicates, and rejects invalid arguments.
#
# RED: SKIPs all cases while source modules are missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

CLI="$AGENTS_DIR/bin/supervisor-report"
WRITER_MODULE="$AGENTS_DIR/hooks/lib/supervisor-state-writer.js"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

read_state() {
    local dir_node="$1" sid="$2"
    run_with_timeout 5 node -e "
const fs = require('fs');
const p = require('path').join(process.argv[1], process.argv[2] + '-supervisor-state.json');
try { process.stdout.write(fs.readFileSync(p,'utf8')); }
catch(e) { console.error('read-state error: '+e.message); process.exit(2); }
" -- "$dir_node" "$sid" 2>&1
}

# --- R1 ----------------------------------------------------------------------
run_r1() {
    require_source "$CLI" "R1: basic report writes finding to state file" || return
    require_source "$WRITER_MODULE" "R1: basic report writes finding to state file" || return
    local tmp tmp_node rc out
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$_AGENTS_DIR_NODE/bin/supervisor-report" \
        --categories workflow --severity warning --detail "test detail" \
        --reporter "test-skill" --session-id "test-r1" >/dev/null 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then fail "R1: basic report writes finding to state file (CLI exited $rc)"; rm -rf "$tmp"; return; fi
    out=$(read_state "$tmp_node" "test-r1" | run_with_timeout 5 node -e "
let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
  const state = JSON.parse(d);
  const f = state.layer1.findings[0];
  if (!f) { console.error('no finding'); process.exit(2); }
  if (f.severity !== 'warning') { console.error('severity:'+f.severity); process.exit(3); }
  if (!Array.isArray(f.categories)||!f.categories.includes('workflow')) { console.error('categories:'+JSON.stringify(f.categories)); process.exit(4); }
  if (f.reporter !== 'test-skill') { console.error('reporter:'+f.reporter); process.exit(5); }
  console.log('OK');
});
" 2>&1)
    rc=$?
    [ $rc -eq 0 ] && [ "$out" = "OK" ] && pass "R1: basic report writes finding to state file" \
        || fail "R1: basic report writes finding to state file (rc=$rc, out=$out)"
    rm -rf "$tmp"
}

# --- R2 ----------------------------------------------------------------------
run_r2() {
    require_source "$CLI" "R2: multi-category finding written correctly" || return
    local tmp tmp_node rc out
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$_AGENTS_DIR_NODE/bin/supervisor-report" \
        --categories "intent,security" --severity error --detail "non-goal touched" \
        --reporter "write-code" --session-id "test-r2" >/dev/null 2>&1
    out=$(read_state "$tmp_node" "test-r2" | run_with_timeout 5 node -e "
let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
  const f = JSON.parse(d).layer1.findings[0];
  if (!f||!Array.isArray(f.categories)) { console.error('no categories'); process.exit(2); }
  if (!f.categories.includes('intent')||!f.categories.includes('security')) { console.error('missing:'+JSON.stringify(f.categories)); process.exit(3); }
  if (f.categories.length !== 2) { console.error('len:'+f.categories.length); process.exit(4); }
  console.log('OK');
});
" 2>&1)
    rc=$?
    [ $rc -eq 0 ] && [ "$out" = "OK" ] && pass "R2: multi-category finding written correctly" \
        || fail "R2: multi-category finding written correctly (rc=$rc, out=$out)"
    rm -rf "$tmp"
}

# --- R3 ----------------------------------------------------------------------
run_r3() {
    require_source "$CLI" "R3: duplicate consecutive finding is deduped" || return
    local tmp tmp_node rc out
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$_AGENTS_DIR_NODE/bin/supervisor-report" \
        --categories workflow --severity warning --detail "same" --reporter "skill-a" --session-id "test-r3" >/dev/null 2>&1
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$_AGENTS_DIR_NODE/bin/supervisor-report" \
        --categories workflow --severity warning --detail "same" --reporter "skill-a" --session-id "test-r3" >/dev/null 2>&1
    out=$(read_state "$tmp_node" "test-r3" | run_with_timeout 5 node -e "
let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
  const n = JSON.parse(d).layer1.findings.length;
  if (n !== 1) { console.error('expected 1, got '+n); process.exit(2); }
  console.log('OK');
});
" 2>&1)
    rc=$?
    [ $rc -eq 0 ] && [ "$out" = "OK" ] && pass "R3: duplicate consecutive finding is deduped" \
        || fail "R3: duplicate consecutive finding is deduped (rc=$rc, out=$out)"
    rm -rf "$tmp"
}

# --- R4 ----------------------------------------------------------------------
run_r4() {
    require_source "$CLI" "R4: missing --categories exits non-zero" || return
    run_with_timeout 5 node "$_AGENTS_DIR_NODE/bin/supervisor-report" \
        --severity warning --detail "d" --reporter "r" --session-id "test-r4" >/dev/null 2>&1
    [ $? -ne 0 ] && pass "R4: missing --categories exits non-zero" \
        || fail "R4: missing --categories exits non-zero"
}

# --- R5 ----------------------------------------------------------------------
run_r5() {
    require_source "$CLI" "R5: invalid category exits non-zero" || return
    local tmp; tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$_AGENTS_DIR_NODE/bin/supervisor-report" \
        --categories "not_real" --severity warning --detail "d" --reporter "r" --session-id "test-r5" >/dev/null 2>&1
    [ $? -ne 0 ] && pass "R5: invalid category exits non-zero" \
        || fail "R5: invalid category exits non-zero"
    rm -rf "$tmp"
}

# --- R6 ----------------------------------------------------------------------
run_r6() {
    require_source "$CLI" "R6: invalid severity exits non-zero" || return
    local tmp; tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$_AGENTS_DIR_NODE/bin/supervisor-report" \
        --categories workflow --severity "critical" --detail "d" --reporter "r" --session-id "test-r6" >/dev/null 2>&1
    [ $? -ne 0 ] && pass "R6: invalid severity exits non-zero" \
        || fail "R6: invalid severity exits non-zero"
    rm -rf "$tmp"
}

# --- R7 ----------------------------------------------------------------------
run_r7() {
    require_source "$CLI" "R7: reporter field present in written finding" || return
    local tmp tmp_node rc out
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$_AGENTS_DIR_NODE/bin/supervisor-report" \
        --categories test --severity notice --detail "flaky" --reporter "run-tests" --session-id "test-r7" >/dev/null 2>&1
    out=$(read_state "$tmp_node" "test-r7" | run_with_timeout 5 node -e "
let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
  const f = JSON.parse(d).layer1.findings[0];
  if (!f||f.reporter !== 'run-tests') { console.error('reporter:'+JSON.stringify(f&&f.reporter)); process.exit(2); }
  console.log('OK');
});
" 2>&1)
    rc=$?
    [ $rc -eq 0 ] && [ "$out" = "OK" ] && pass "R7: reporter field present in written finding" \
        || fail "R7: reporter field present in written finding (rc=$rc, out=$out)"
    rm -rf "$tmp"
}

# --- R8 ----------------------------------------------------------------------
run_r8() {
    require_source "$CLI" "R8: missing --session-id exits non-zero" || return
    run_with_timeout 5 node "$_AGENTS_DIR_NODE/bin/supervisor-report" \
        --categories workflow --severity warning --detail "d" --reporter "r" >/dev/null 2>&1
    [ $? -ne 0 ] && pass "R8: missing --session-id exits non-zero" \
        || fail "R8: missing --session-id exits non-zero"
}

run_r1
run_r2
run_r3
run_r4
run_r5
run_r6
run_r7
run_r8

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
