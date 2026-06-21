#!/bin/bash
# tests/feature-1027-state-schema-eligible-phase.sh
# Tests: hooks/lib/supervisor-state-schema.js
# Tags: supervisor, em-supervisor, l2-findings, scope:issue-specific
# Tests for issue #1027 — schema fields findings_surfaced_at + l2_eligible_phase.
#
# RED on unmodified codebase: schema does not yet expose the new fields or
# the L2_ELIGIBLE_PHASE_VALUES export.
#
# # L3 gap
# This is L1 (pure schema unit). No L3 gap — schema is a deterministic
# JavaScript module with no host/IO dependencies; full coverage at L1.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

SCHEMA_MODULE="$AGENTS_DIR/hooks/lib/supervisor-state-schema.js"
SCHEMA_MODULE_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"

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

# --- E1: createEmptyState includes the two new fields with null defaults ----
run_e1() {
    require_source "$SCHEMA_MODULE" "E1: createEmptyState exposes findings_surfaced_at + l2_eligible_phase" || return
    local rc
    run_with_timeout 10 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('sid-e1');
if (!('findings_surfaced_at' in st.layer2)) { console.error('missing findings_surfaced_at'); process.exit(2); }
if (st.layer2.findings_surfaced_at !== null) { console.error('findings_surfaced_at not null'); process.exit(3); }
if (!('l2_eligible_phase' in st.layer2)) { console.error('missing l2_eligible_phase'); process.exit(4); }
if (st.layer2.l2_eligible_phase !== null) { console.error('l2_eligible_phase not null'); process.exit(5); }
" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = "0" ]; then
        pass "E1: createEmptyState exposes findings_surfaced_at + l2_eligible_phase (both null)"
    else
        fail "E1: createEmptyState exposes findings_surfaced_at + l2_eligible_phase (rc=$rc)"
    fi
}

# --- E2: validate accepts null and post_final_report_window for l2_eligible_phase ----
run_e2() {
    require_source "$SCHEMA_MODULE" "E2: validate accepts l2_eligible_phase null + post_final_report_window" || return
    local rc
    run_with_timeout 10 node -e "
const s = require('$SCHEMA_MODULE_NODE');
function mk(val) {
  const st = s.createEmptyState('sid-e2');
  st.layer2.l2_eligible_phase = val;
  return st;
}
const r1 = s.validate(mk(null));
if (!r1.ok) { console.error('null rejected: ' + r1.errors.join(';')); process.exit(2); }
const r2 = s.validate(mk('post_final_report_window'));
if (!r2.ok) { console.error('post_final_report_window rejected: ' + r2.errors.join(';')); process.exit(3); }
" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = "0" ]; then
        pass "E2: validate accepts l2_eligible_phase null + post_final_report_window"
    else
        fail "E2: validate accepts l2_eligible_phase null + post_final_report_window (rc=$rc)"
    fi
}

# --- E3: validate rejects "normal_run" and other strings ---------------------
run_e3() {
    require_source "$SCHEMA_MODULE" "E3: validate rejects invalid l2_eligible_phase values" || return
    local rc
    run_with_timeout 10 node -e "
const s = require('$SCHEMA_MODULE_NODE');
function check(val) {
  const st = s.createEmptyState('sid-e3');
  st.layer2.l2_eligible_phase = val;
  return s.validate(st).ok;
}
if (check('normal_run')) { console.error('normal_run accepted'); process.exit(2); }
if (check('bogus')) { console.error('bogus accepted'); process.exit(3); }
if (check(42)) { console.error('integer accepted'); process.exit(4); }
" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = "0" ]; then
        pass "E3: validate rejects normal_run / bogus / integer for l2_eligible_phase"
    else
        fail "E3: validate rejects invalid l2_eligible_phase values (rc=$rc)"
    fi
}

# --- E4: validate accepts null or ISO string for findings_surfaced_at; rejects others ----
run_e4() {
    require_source "$SCHEMA_MODULE" "E4: findings_surfaced_at type validation" || return
    local rc
    run_with_timeout 10 node -e "
const s = require('$SCHEMA_MODULE_NODE');
function check(val) {
  const st = s.createEmptyState('sid-e4');
  st.layer2.findings_surfaced_at = val;
  return s.validate(st).ok;
}
if (!check(null)) { console.error('null rejected'); process.exit(2); }
if (!check('2026-06-21T12:00:00Z')) { console.error('ISO string rejected'); process.exit(3); }
if (check(123456)) { console.error('number accepted'); process.exit(4); }
if (check([])) { console.error('array accepted'); process.exit(5); }
" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = "0" ]; then
        pass "E4: findings_surfaced_at accepts null/string, rejects number/array"
    else
        fail "E4: findings_surfaced_at type validation (rc=$rc)"
    fi
}

# --- E5: L2_ELIGIBLE_PHASE_VALUES export ------------------------------------
run_e5() {
    require_source "$SCHEMA_MODULE" "E5: L2_ELIGIBLE_PHASE_VALUES exported" || return
    local rc
    run_with_timeout 10 node -e "
const s = require('$SCHEMA_MODULE_NODE');
if (!Array.isArray(s.L2_ELIGIBLE_PHASE_VALUES)) { console.error('not array'); process.exit(2); }
const v = s.L2_ELIGIBLE_PHASE_VALUES;
if (v.length !== 2) { console.error('wrong length: ' + v.length); process.exit(3); }
if (v.indexOf(null) === -1) { console.error('missing null'); process.exit(4); }
if (v.indexOf('post_final_report_window') === -1) { console.error('missing post_final_report_window'); process.exit(5); }
" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = "0" ]; then
        pass "E5: L2_ELIGIBLE_PHASE_VALUES equals [null, 'post_final_report_window']"
    else
        fail "E5: L2_ELIGIBLE_PHASE_VALUES export (rc=$rc)"
    fi
}

# --- E6: round-trip of new fields via JSON serialize/parse + validate -------
run_e6() {
    require_source "$SCHEMA_MODULE" "E6: round-trip new fields through JSON" || return
    local rc
    run_with_timeout 10 node -e "
const s = require('$SCHEMA_MODULE_NODE');
const st = s.createEmptyState('sid-e6');
st.layer2.findings_surfaced_at = '2026-06-21T01:23:45Z';
st.layer2.l2_eligible_phase = 'post_final_report_window';
const raw = JSON.stringify(st);
const parsed = JSON.parse(raw);
if (parsed.layer2.findings_surfaced_at !== '2026-06-21T01:23:45Z') { console.error('roundtrip findings_surfaced_at'); process.exit(2); }
if (parsed.layer2.l2_eligible_phase !== 'post_final_report_window') { console.error('roundtrip l2_eligible_phase'); process.exit(3); }
const r = s.validate(parsed);
if (!r.ok) { console.error('validate failed: ' + r.errors.join(';')); process.exit(4); }
" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = "0" ]; then
        pass "E6: round-trip JSON serialize -> parse -> validate preserves both new fields"
    else
        fail "E6: round-trip new fields through JSON (rc=$rc)"
    fi
}

run_e1
run_e2
run_e3
run_e4
run_e5
run_e6

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
