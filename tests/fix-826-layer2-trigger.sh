#!/bin/bash
# tests/fix-826-layer2-trigger.sh
# Tests: hooks/lib/supervisor-state-writer.js
# Tags: supervisor, em-supervisor, layer2, appendfinding
# RED for issue #826.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

seed_state() {
    local tmp="$1" sid="$2" layer2_json="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.layer2 = $layer2_json;
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
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

# A1 (RED→GREEN): empty state → appendFinding() with valid finding → layer2.next_check_at is non-null ISO 8601 string
run_A1() {
    local tmp val rc
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const result = w.appendFinding('a1-sid', {categories:['workflow'],severity:'warning',detail:'test finding',reporter:'test'});
process.exit(result === true ? 0 : 1);
" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "a1-sid" "layer2.next_check_at")
    rm -rf "$tmp"
    # appendFinding must return true AND layer2.next_check_at must be a non-null ISO 8601 string
    if [ $rc -eq 0 ] && [ "$val" != "null" ] && [ -n "$val" ] && [ "$val" != '""' ]; then
        pass "A1: empty state -> appendFinding() -> layer2.next_check_at is non-null ISO 8601 string"
    else
        fail "A1: empty state -> appendFinding() -> layer2.next_check_at is non-null ISO 8601 string (rc=$rc, val=$val)"
    fi
}

# A2 (RED→GREEN): state with next_check_at already set → appendFinding() → next_check_at unchanged (no-clobber)
run_A2() {
    local tmp val rc
    tmp="$(mktemp -d)"
    local fixed_ts="2026-01-01T00:00:00.000Z"
    seed_state "$tmp" "a2-sid" "{ next_check_at: '$fixed_ts', last_run_at: null, cumulative_severity: null, findings: [] }"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const result = w.appendFinding('a2-sid', {categories:['workflow'],severity:'warning',detail:'second finding',reporter:'test'});
process.exit(result === true ? 0 : 1);
" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "a2-sid" "layer2.next_check_at")
    rm -rf "$tmp"
    # appendFinding must return true AND layer2.next_check_at must remain the original value (no-clobber)
    # The fix must set next_check_at when null but NOT overwrite an existing value.
    # To confirm no-clobber, the value must equal the seeded fixed_ts.
    # This test is RED→GREEN: currently appendFinding does not set next_check_at at all,
    # so the value stays "2026-01-01T00:00:00.000Z" — but we need to verify it alongside A1.
    # The RED condition: A1 must pass first (appendFinding sets next_check_at), which confirms
    # the feature is implemented. A2 verifies the no-clobber half. Together they form the contract.
    # However, to make A2 standalone-RED against current code, we check that appendFinding
    # also sets next_check_at on this call (which means it should NOT, since one is already set).
    # We verify the value is EXACTLY the seeded value (not a new timestamp).
    if [ $rc -eq 0 ] && [ "$val" = "\"$fixed_ts\"" ]; then
        pass "A2: next_check_at already set -> appendFinding() -> next_check_at unchanged (no-clobber)"
    else
        fail "A2: next_check_at already set -> appendFinding() -> next_check_at unchanged (no-clobber) (rc=$rc, val=$val)"
    fi
}

# A3 (RED→GREEN, dedup path): state already contains same finding + next_check_at === null
#   → appendFinding() same finding → returns true AND next_check_at non-null
run_A3() {
    local tmp val rc
    tmp="$(mktemp -d)"
    # Pre-seed a finding that matches what we will call appendFinding with
    seed_state "$tmp" "a3-sid" "{ next_check_at: null, last_run_at: null, cumulative_severity: null, findings: [] }"
    # First call: add the finding
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.appendFinding('a3-sid', {categories:['workflow'],severity:'warning',detail:'dedup-finding',reporter:'test'});
" >/dev/null 2>&1
    # Reset next_check_at to null to simulate pre-fix state where first call didn't set it
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const fs = require('fs');
const st = w.readState('a3-sid');
st.layer2.next_check_at = null;
fs.writeFileSync(w.getStatePath('a3-sid'), JSON.stringify(st));
" >/dev/null 2>&1
    # Second call with same finding (dedup path — returns true without pushing)
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const result = w.appendFinding('a3-sid', {categories:['workflow'],severity:'warning',detail:'dedup-finding',reporter:'test'});
process.exit(result === true ? 0 : 1);
" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "a3-sid" "layer2.next_check_at")
    rm -rf "$tmp"
    # On the dedup path, appendFinding returns true early (before writing).
    # The fix must ALSO set next_check_at even on the dedup path when it is null.
    if [ $rc -eq 0 ] && [ "$val" != "null" ] && [ -n "$val" ] && [ "$val" != '""' ]; then
        pass "A3: dedup path + next_check_at null -> appendFinding() -> returns true AND next_check_at non-null"
    else
        fail "A3: dedup path + next_check_at null -> appendFinding() -> returns true AND next_check_at non-null (rc=$rc, val=$val)"
    fi
}

# A3b (RED→GREEN, partial layer2): same as A3 but seed state has layer2: {} (next_check_at key absent)
run_A3b() {
    local tmp val rc
    tmp="$(mktemp -d)"
    # Seed with layer2: {} — no next_check_at key at all
    seed_state "$tmp" "a3b-sid" "{}"
    # First call: add the finding
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.appendFinding('a3b-sid', {categories:['workflow'],severity:'warning',detail:'partial-layer2-finding',reporter:'test'});
" >/dev/null 2>&1
    # Force layer2 back to {} to simulate partial (S-1-era) state
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const fs = require('fs');
const st = w.readState('a3b-sid');
st.layer2 = {};
fs.writeFileSync(w.getStatePath('a3b-sid'), JSON.stringify(st));
" >/dev/null 2>&1
    # Call appendFinding with same finding (dedup path with layer2:{})
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const result = w.appendFinding('a3b-sid', {categories:['workflow'],severity:'warning',detail:'partial-layer2-finding',reporter:'test'});
process.exit(result === true ? 0 : 1);
" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "a3b-sid" "layer2.next_check_at")
    rm -rf "$tmp"
    # With layer2:{} (next_check_at key absent → undefined → treated as null),
    # appendFinding must set next_check_at to a non-null ISO 8601 string.
    if [ $rc -eq 0 ] && [ "$val" != "null" ] && [ -n "$val" ] && [ "$val" != '""' ]; then
        pass "A3b: partial layer2:{} + next_check_at absent -> appendFinding() -> next_check_at non-null"
    else
        fail "A3b: partial layer2:{} + next_check_at absent -> appendFinding() -> next_check_at non-null (rc=$rc, val=$val)"
    fi
}

# A4 (regression / boundary lock — already passes current code):
# invalid finding (missing severity) → appendFinding() returns false, on-disk state unchanged
# (next_check_at still null). Documents the validation boundary is preserved post-fix.
run_A4() {
    local tmp val rc before_val
    tmp="$(mktemp -d)"
    seed_state "$tmp" "a4-sid" "{ next_check_at: null, last_run_at: null, cumulative_severity: null, findings: [] }"
    before_val=$(read_field "$tmp" "a4-sid" "layer2.next_check_at")
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
// Invalid: missing severity field
const result = w.appendFinding('a4-sid', {categories:['workflow'],detail:'x',reporter:'r'});
process.exit(result === false ? 0 : 1);
" >/dev/null 2>&1
    rc=$?
    val=$(read_field "$tmp" "a4-sid" "layer2.next_check_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" = "null" ] && [ "$before_val" = "null" ]; then
        pass "A4: invalid finding (missing severity) -> appendFinding() returns false, state unchanged"
    else
        fail "A4: invalid finding (missing severity) -> appendFinding() returns false, state unchanged (rc=$rc, val=$val, before=$before_val)"
    fi
}

run_A1
run_A2
run_A3
run_A3b
run_A4

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
