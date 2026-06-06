#!/bin/bash
# tests/feature-719-supervisor-write-layer2-cli.sh
# Tests: bin/supervisor-write-layer2
# Tags: supervisor, em-supervisor, cli, layer2
# RED for issue #719.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

CLI="$AGENTS_DIR/bin/supervisor-write-layer2"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

read_field() {
    local tmp="$1" sid="$2" path="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
const parts = '$path'.split('.');
let cur = st;
for (const p of parts) { if (cur == null) break; cur = cur[p]; }
process.stdout.write(JSON.stringify(cur));
" 2>/dev/null
}

run_c1() {
    require_source "$CLI" "C1: --next-check-at sets layer2.next_check_at" || return
    local tmp sid val rc
    tmp="$(mktemp -d)"; sid="c1-sid"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" --next-check-at "2026-06-06T12:00:00Z" --session-id "$sid" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "$sid" "layer2.next_check_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" = "\"2026-06-06T12:00:00Z\"" ]; then
        pass "C1: --next-check-at sets layer2.next_check_at"
    else
        fail "C1: --next-check-at sets layer2.next_check_at (rc=$rc, val=$val)"
    fi
}

run_c2() {
    require_source "$CLI" "C2: --last-run-at + --cumulative-severity" || return
    local tmp sid v1 v2 rc
    tmp="$(mktemp -d)"; sid="c2-sid"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" --last-run-at "2026-06-06T11:00:00Z" --cumulative-severity warning --session-id "$sid" >/dev/null 2>&1
    rc=$?
    v1=$(read_field "$tmp" "$sid" "layer2.last_run_at")
    v2=$(read_field "$tmp" "$sid" "layer2.cumulative_severity")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$v1" = "\"2026-06-06T11:00:00Z\"" ] && [ "$v2" = "\"warning\"" ]; then
        pass "C2: --last-run-at + --cumulative-severity"
    else
        fail "C2: --last-run-at + --cumulative-severity (rc=$rc, v1=$v1, v2=$v2)"
    fi
}

run_c3() {
    require_source "$CLI" "C3: --finding-* flags append to layer2.findings" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"; sid="c3-sid"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" \
        --finding-categories intent,workflow \
        --finding-severity error \
        --finding-detail "test detail" \
        --finding-reporter supervisor \
        --session-id "$sid" >/dev/null 2>&1
    rc=$?
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
const fs2 = st.layer2.findings;
if (!Array.isArray(fs2) || fs2.length !== 1) { console.error('len'); process.exit(2); }
const f = fs2[0];
if (!Array.isArray(f.categories) || f.categories.length !== 2) { console.error('cat'); process.exit(3); }
if (f.categories[0] !== 'intent' || f.categories[1] !== 'workflow') { console.error('catval'); process.exit(4); }
if (f.severity !== 'error') { console.error('sev'); process.exit(5); }
if (f.detail !== 'test detail') { console.error('detail'); process.exit(6); }
if (f.reporter !== 'supervisor') { console.error('reporter'); process.exit(7); }
console.log('OK');
" 2>&1)
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "C3: --finding-* flags append to layer2.findings"
    else
        fail "C3: --finding-* flags append to layer2.findings (rc=$rc, out=$out)"
    fi
}

run_c4() {
    require_source "$CLI" "C4: missing --session-id exits non-zero" || return
    local tmp rc
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" --next-check-at "2026-06-06T12:00:00Z" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then
        pass "C4: missing --session-id exits non-zero"
    else
        fail "C4: missing --session-id exits non-zero (rc=$rc)"
    fi
}

run_c5() {
    require_source "$CLI" "C5: invalid --cumulative-severity exits non-zero" || return
    local tmp rc
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" --cumulative-severity critical --session-id "c5-sid" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then
        pass "C5: invalid --cumulative-severity exits non-zero"
    else
        fail "C5: invalid --cumulative-severity exits non-zero (rc=$rc)"
    fi
}

run_c6() {
    require_source "$CLI" "C6: no mutating flags exits non-zero" || return
    local tmp rc
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" --session-id "c6-sid" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then
        pass "C6: no mutating flags exits non-zero"
    else
        fail "C6: no mutating flags exits non-zero (rc=$rc)"
    fi
}

run_c7() {
    require_source "$CLI" "C7: --clear-next-check-at nulls layer2.next_check_at" || return
    local tmp sid val rc
    tmp="$(mktemp -d)"; sid="c7-sid"
    # seed with a value first
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" --next-check-at "2026-06-06T12:00:00Z" --session-id "$sid" >/dev/null 2>&1
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI" --clear-next-check-at --session-id "$sid" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "$sid" "layer2.next_check_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" = "null" ]; then
        pass "C7: --clear-next-check-at nulls layer2.next_check_at"
    else
        fail "C7: --clear-next-check-at nulls layer2.next_check_at (rc=$rc, val=$val)"
    fi
}

run_c1
run_c2
run_c3
run_c4
run_c5
run_c6
run_c7

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
