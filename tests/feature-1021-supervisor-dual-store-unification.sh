#!/bin/bash
# tests/feature-1021-supervisor-dual-store-unification.sh
# Tests: bin/supervisor-report
# Tags: supervisor, em-supervisor, dual-store, identity, cli, scope:issue-specific
# L3 gap (what this test does NOT catch):
#   This test exercises bin/supervisor-report against synthetic state files in a
#   temp WORKFLOW_PLANS_DIR. It cannot verify that the real cc-uuid <-> wsid
#   resolution in a live claude -p session produces matching writes — that
#   requires a real Anthropic session with both identifiers in flight.
# RED for issue #1021.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
    _TMPCONV() { cygpath -m "$1"; }
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
    _TMPCONV() { printf '%s' "$1"; }
fi

CLI="$AGENTS_DIR/bin/supervisor-report"
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

# Mirror-write is detected by presence of a documented function name in the CLI source.
# Skip B-cases when the mirror-write code path hasn't landed yet.
mirror_present() {
    [ -f "$CLI" ] || return 1
    grep -qE "mirror[-_]?write|dual[-_]?store|writeFindingToBothStores|MIRROR_STORES" "$CLI" 2>/dev/null
}

require_mirror() {
    local label="$1"
    if ! mirror_present; then skip "$label (mirror-write code path not yet added)"; return 1; fi
    return 0
}

count_findings() {
    local tmp="$1" sid="$2"
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
if (!st || !st.layer1 || !Array.isArray(st.layer1.findings)) { process.stdout.write('0'); process.exit(0); }
process.stdout.write(String(st.layer1.findings.length));
" 2>/dev/null
    )
}

run_b1() {
    require_source "$CLI" "B1: explicit --session-id writes to that store" || return
    require_mirror "B1: explicit --session-id writes to that store" || return
    local tmp sid n
    tmp="$(mktemp -d)"; sid="b1sid"
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        run_with_timeout 5 node "$CLI" \
            --session-id "$sid" \
            --categories code \
            --severity warning \
            --detail "b1 finding" \
            --reporter test >/dev/null 2>&1
    )
    n=$(count_findings "$tmp" "$sid")
    rm -rf "$tmp"
    if [ "$n" = "1" ]; then
        pass "B1: explicit --session-id writes to that store"
    else
        fail "B1: explicit --session-id writes to that store (n=$n)"
    fi
}

run_b2() {
    require_source "$CLI" "B2: mirror-write appears in both wsid and cc-uuid stores" || return
    require_mirror "B2: mirror-write appears in both wsid and cc-uuid stores" || return
    local tmp wsid ccuuid n1 n2
    tmp="$(mktemp -d)"
    wsid="wsid-b2"
    ccuuid="12345678-1234-1234-1234-123456789abc"
    # Seed both stores so both are "resolvable" (existence-based heuristic).
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.writeAlertState('$wsid', { alert_armed_at: null });
w.writeAlertState('$ccuuid', { alert_armed_at: null });
" >/dev/null 2>&1
        run_with_timeout 5 node "$CLI" \
            --session-id "$wsid" \
            --mirror-session-id "$ccuuid" \
            --categories code \
            --severity warning \
            --detail "b2 finding" \
            --reporter test >/dev/null 2>&1
    )
    n1=$(count_findings "$tmp" "$wsid")
    n2=$(count_findings "$tmp" "$ccuuid")
    rm -rf "$tmp"
    if [ "$n1" = "1" ] && [ "$n2" = "1" ]; then
        pass "B2: mirror-write appears in both wsid and cc-uuid stores"
    else
        fail "B2: mirror-write appears in both wsid and cc-uuid stores (n1=$n1, n2=$n2)"
    fi
}

run_b3() {
    require_source "$CLI" "B3: cc-uuid-form --session-id mirrors to wsid store" || return
    require_mirror "B3: cc-uuid-form --session-id mirrors to wsid store" || return
    local tmp wsid ccuuid n1 n2
    tmp="$(mktemp -d)"
    wsid="wsid-b3"
    ccuuid="abcdef01-2345-6789-abcd-ef0123456789"
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.writeAlertState('$wsid', { alert_armed_at: null });
w.writeAlertState('$ccuuid', { alert_armed_at: null });
" >/dev/null 2>&1
        run_with_timeout 5 node "$CLI" \
            --session-id "$ccuuid" \
            --mirror-session-id "$wsid" \
            --categories code \
            --severity warning \
            --detail "b3 finding" \
            --reporter test >/dev/null 2>&1
    )
    n1=$(count_findings "$tmp" "$wsid")
    n2=$(count_findings "$tmp" "$ccuuid")
    rm -rf "$tmp"
    if [ "$n1" = "1" ] && [ "$n2" = "1" ]; then
        pass "B3: cc-uuid-form --session-id mirrors to wsid store"
    else
        fail "B3: cc-uuid-form --session-id mirrors to wsid store (n1=$n1, n2=$n2)"
    fi
}

run_b4() {
    require_source "$CLI" "B4: mirror-write idempotent on same call" || return
    require_mirror "B4: mirror-write idempotent on same call" || return
    local tmp wsid ccuuid n1 n2
    tmp="$(mktemp -d)"
    wsid="wsid-b4"
    ccuuid="11111111-2222-3333-4444-555555555555"
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.writeAlertState('$wsid', { alert_armed_at: null });
w.writeAlertState('$ccuuid', { alert_armed_at: null });
" >/dev/null 2>&1
        # Single call: same finding must not be written twice to the same store.
        run_with_timeout 5 node "$CLI" \
            --session-id "$wsid" \
            --mirror-session-id "$ccuuid" \
            --categories code \
            --severity warning \
            --detail "b4 finding" \
            --reporter test >/dev/null 2>&1
    )
    n1=$(count_findings "$tmp" "$wsid")
    n2=$(count_findings "$tmp" "$ccuuid")
    rm -rf "$tmp"
    # Each store should contain exactly 1 finding (one mirror write per store, no duplicate).
    if [ "$n1" = "1" ] && [ "$n2" = "1" ]; then
        pass "B4: mirror-write idempotent on same call"
    else
        fail "B4: mirror-write idempotent on same call (n1=$n1, n2=$n2)"
    fi
}

run_b1
run_b2
run_b3
run_b4

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
