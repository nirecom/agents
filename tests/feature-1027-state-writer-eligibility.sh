#!/bin/bash
# tests/feature-1027-state-writer-eligibility.sh
# Tests: hooks/lib/supervisor-state-writer.js, hooks/lib/supervisor-state-schema.js
# Tags: supervisor, em-supervisor, l2-findings, scope:issue-specific
# Tests for issue #1027 / #997 — writer accepts new fields and ensureLayer2Scheduled
# implements the anchor-vs-eligibility split.
#
# # L3 gap
# L2 here exercises the writer module with a real tmpdir-backed WORKFLOW_PLANS_DIR.
# Real Stop-hook firing under a live `claude -p` session is covered separately
# (feature-1027-stop-l2-findings-display.sh, RUN_E2E-gated).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
WRITER_SRC="$AGENTS_DIR/hooks/lib/supervisor-state-writer.js"

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

# --- W1: writeLayer2State accepts findings_surfaced_at + l2_eligible_phase ---
run_w1() {
    require_source "$WRITER_SRC" "W1: writeLayer2State accepts new keys" || return
    local tmp rc
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const ok = w.writeLayer2State('w1-sid', { findings_surfaced_at: '2026-06-21T02:00:00Z', l2_eligible_phase: 'post_final_report_window' });
if (!ok) { console.error('write returned false'); process.exit(2); }
const st = w.readState('w1-sid');
if (!st) { console.error('state not readable'); process.exit(3); }
if (st.layer2.findings_surfaced_at !== '2026-06-21T02:00:00Z') { console.error('findings_surfaced_at not persisted'); process.exit(4); }
if (st.layer2.l2_eligible_phase !== 'post_final_report_window') { console.error('l2_eligible_phase not persisted'); process.exit(5); }
" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ "$rc" = "0" ]; then
        pass "W1: writeLayer2State persists findings_surfaced_at + l2_eligible_phase"
    else
        fail "W1: writeLayer2State persists new keys (rc=$rc)"
    fi
}

# --- W2: anchor present + l2_eligible_phase=null -> arm SKIPPED (regression) -
run_w2() {
    require_source "$WRITER_SRC" "W2: anchor + null eligibility -> arm skipped" || return
    local tmp rc
    tmp="$(mktemp -d)"
    # create anchor file
    : > "$tmp/w2-sid-final-report-env.json"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('w2-sid');
st.layer2.l2_eligible_phase = null;
fs.writeFileSync(w.getStatePath('w2-sid'), JSON.stringify(st));
w.ensureLayer2Scheduled(st, 'w2-sid');
if (st.layer2.l2_armed_at !== null) { console.error('arm fired despite anchor'); process.exit(2); }
" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ "$rc" = "0" ]; then
        pass "W2: anchor present + null eligibility -> l2_armed_at remains null"
    else
        fail "W2: anchor + null eligibility blocked arm (rc=$rc)"
    fi
}

# --- W3: anchor present + l2_eligible_phase=post_final_report_window -> arm proceeds ---
run_w3() {
    require_source "$WRITER_SRC" "W3: anchor + post_final_report_window eligibility -> arm fires" || return
    local tmp rc
    tmp="$(mktemp -d)"
    : > "$tmp/w3-sid-final-report-env.json"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('w3-sid');
st.layer2.l2_eligible_phase = 'post_final_report_window';
fs.writeFileSync(w.getStatePath('w3-sid'), JSON.stringify(st));
w.ensureLayer2Scheduled(st, 'w3-sid');
if (st.layer2.l2_armed_at === null) { console.error('arm did not fire under eligibility'); process.exit(2); }
if (st.layer2.l2_phase !== 'pending') { console.error('phase not set to pending'); process.exit(3); }
" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ "$rc" = "0" ]; then
        pass "W3: anchor + post_final_report_window eligibility -> arm fires (l2_phase=pending)"
    else
        fail "W3: anchor + eligibility -> arm fires (rc=$rc)"
    fi
}

# --- W4: anchor absent + null eligibility -> arm proceeds (unchanged baseline) -
run_w4() {
    require_source "$WRITER_SRC" "W4: anchor absent + null eligibility -> arm proceeds (baseline)" || return
    local tmp rc
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('w4-sid');
fs.writeFileSync(w.getStatePath('w4-sid'), JSON.stringify(st));
w.ensureLayer2Scheduled(st, 'w4-sid');
if (st.layer2.l2_armed_at === null) { console.error('arm did not fire baseline'); process.exit(2); }
" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ "$rc" = "0" ]; then
        pass "W4: anchor absent + null eligibility -> arm fires (baseline)"
    else
        fail "W4: baseline arm path (rc=$rc)"
    fi
}

# --- W5: l2_phase=done overrides eligibility ----------------------------------
run_w5() {
    require_source "$WRITER_SRC" "W5: l2_phase=done overrides eligibility" || return
    local tmp rc
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('w5-sid');
st.layer2.l2_phase = 'done';
st.layer2.l2_eligible_phase = 'post_final_report_window';
fs.writeFileSync(w.getStatePath('w5-sid'), JSON.stringify(st));
w.ensureLayer2Scheduled(st, 'w5-sid');
if (st.layer2.l2_armed_at !== null) { console.error('arm fired despite done'); process.exit(2); }
" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ "$rc" = "0" ]; then
        pass "W5: l2_phase=done overrides eligibility (no arm)"
    else
        fail "W5: done overrides eligibility (rc=$rc)"
    fi
}

# --- W6: up-cast — state without the new fields still validates --------------
run_w6() {
    require_source "$WRITER_SRC" "W6: legacy state without new fields validates" || return
    local tmp rc
    tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
// Build legacy-shape state WITHOUT the new fields.
const st = {
  version: 1,
  session_id: 'w6-sid',
  created_at: new Date().toISOString(),
  last_updated: new Date().toISOString(),
  layer1: { findings: [] },
  layer2: { l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null, l2_cause: null, l2_retry_count: 0 },
  layer3: {},
};
fs.writeFileSync(w.getStatePath('w6-sid'), JSON.stringify(st));
const r = s.validate(st);
if (!r.ok) { console.error('legacy state failed validate: ' + r.errors.join(';')); process.exit(2); }
const ok = w.writeLayer2State('w6-sid', { l2_eligible_phase: 'post_final_report_window' });
if (!ok) { console.error('write upcast failed'); process.exit(3); }
const reread = w.readState('w6-sid');
if (reread.layer2.l2_eligible_phase !== 'post_final_report_window') { console.error('upcast value not present'); process.exit(4); }
" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ "$rc" = "0" ]; then
        pass "W6: legacy state without new fields validates; writer up-casts on write"
    else
        fail "W6: up-cast path (rc=$rc)"
    fi
}

# --- W7: anchor absent + l2_eligible_phase=post_final_report_window -> arm fires ---
run_w7() {
    require_source "$WRITER_SRC" "W7: anchor absent + post_final_report_window eligibility -> arm fires" || return
    local tmp rc
    tmp="$(mktemp -d)"
    # No anchor file created.
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('w7-sid');
st.layer2.l2_eligible_phase = 'post_final_report_window';
fs.writeFileSync(w.getStatePath('w7-sid'), JSON.stringify(st));
w.ensureLayer2Scheduled(st, 'w7-sid');
if (st.layer2.l2_armed_at === null) { console.error('arm did not fire (anchor absent + eligibility)'); process.exit(2); }
if (st.layer2.l2_phase !== 'pending') { console.error('phase not set to pending'); process.exit(3); }
" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ "$rc" = "0" ]; then
        pass "W7: anchor absent + post_final_report_window eligibility -> arm fires (l2_phase=pending)"
    else
        fail "W7: anchor absent + eligibility arm (rc=$rc)"
    fi
}

run_w1
run_w2
run_w3
run_w4
run_w5
run_w6
run_w7

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
