#!/bin/bash
# tests/fix-891-l2-phase-schema-writer.sh
# Tests: hooks/lib/supervisor-state-schema.js, hooks/lib/supervisor-state-writer.js
# Tags: supervisor, em-supervisor, layer2, l2-phase, schema
# L3 gap (what this test does NOT catch):
# - hook registration in settings.json Stop hooks
# - real Claude Code transcript format differences
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh

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

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

seed_state_raw() {
    local tmp="$1" sid="$2" layer2_json="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const fs = require('fs');
const now = new Date().toISOString();
const st = {
  version: 1,
  session_id: '$sid',
  created_at: now,
  last_updated: now,
  layer1: { findings: [] },
  layer2: $layer2_json,
  layer3: {},
};
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

read_l2_armed_at() {
    local tmp="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const fs = require('fs');
try {
  const raw = fs.readFileSync(w.getStatePath('$sid'), 'utf8');
  const st = JSON.parse(raw);
  const v = st && st.layer2 ? st.layer2.l2_armed_at : undefined;
  process.stdout.write(v === undefined ? 'undefined' : (v === null ? 'null' : String(v)));
} catch (e) {
  process.stdout.write('error:' + e.message);
}
" 2>/dev/null
}

read_l2_phase() {
    local tmp="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const fs = require('fs');
try {
  const raw = fs.readFileSync(w.getStatePath('$sid'), 'utf8');
  const st = JSON.parse(raw);
  const v = st && st.layer2 ? st.layer2.l2_phase : undefined;
  process.stdout.write(v === undefined ? 'undefined' : (v === null ? 'null' : String(v)));
} catch (e) {
  process.stdout.write('error:' + e.message);
}
" 2>/dev/null
}

# ─── Schema tests (G20–G23) ──────────────────────────────────────────────────

run_g20() {
    require_source "$AGENTS_DIR/hooks/lib/supervisor-state-schema.js" "G20: createEmptyState includes l2_phase null" || return
    local out
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
const st = s.createEmptyState('g20-sid');
process.stdout.write(st.layer2 && ('l2_phase' in st.layer2) ? String(st.layer2.l2_phase) : 'missing');
" 2>/dev/null)
    if [ "$out" = "null" ]; then
        pass "G20: createEmptyState includes l2_phase null"
    else
        fail "G20: createEmptyState includes l2_phase null (got: $out)"
    fi
}

run_g21() {
    require_source "$AGENTS_DIR/hooks/lib/supervisor-state-schema.js" "G21: validate rejects invalid l2_phase value" || return
    local out
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
const st = s.createEmptyState('g21-sid');
st.layer2.l2_phase = 'bogus';
const r = s.validate(st);
process.stdout.write(r.ok ? 'ok' : 'rejected');
" 2>/dev/null)
    if [ "$out" = "rejected" ]; then
        pass "G21: validate rejects invalid l2_phase value"
    else
        fail "G21: validate rejects invalid l2_phase value (got: $out)"
    fi
}

run_g22() {
    require_source "$AGENTS_DIR/hooks/lib/supervisor-state-schema.js" "G22: validate accepts all valid l2_phase values" || return
    local out
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
const phases = [null, 'pending', 'done', 'frozen'];
let failed = '';
for (const p of phases) {
  const st = s.createEmptyState('g22-sid');
  st.layer2.l2_phase = p;
  const r = s.validate(st);
  if (!r.ok) { failed = String(p); break; }
}
process.stdout.write(failed ? ('failed:' + failed) : 'ok');
" 2>/dev/null)
    if [ "$out" = "ok" ]; then
        pass "G22: validate accepts all valid l2_phase values"
    else
        fail "G22: validate accepts all valid l2_phase values (got: $out)"
    fi
}

run_g23() {
    require_source "$AGENTS_DIR/hooks/lib/supervisor-state-schema.js" "G23: validate accepts state missing l2_phase (backward compat)" || return
    local out
    out=$(run_with_timeout 5 node -e "
const s = require('$SCHEMA_NODE');
const st = s.createEmptyState('g23-sid');
if (st.layer2 && 'l2_phase' in st.layer2) delete st.layer2.l2_phase;
const r = s.validate(st);
process.stdout.write(r.ok ? 'ok' : 'rejected:' + r.errors.join(','));
" 2>/dev/null)
    if [ "$out" = "ok" ]; then
        pass "G23: validate accepts state missing l2_phase (backward compat)"
    else
        fail "G23: validate accepts state missing l2_phase (backward compat) (got: $out)"
    fi
}

# ─── Writer tests (G24–G33) ──────────────────────────────────────────────────

run_g24() {
    require_source "$AGENTS_DIR/hooks/lib/supervisor-state-writer.js" "G24: l2_phase=done -> ensureLayer2Scheduled early-returns, l2_armed_at stays null" || return
    local out
    out=$(run_with_timeout 5 node -e "
const writerMod = require('$WRITER_NODE');
const state = { layer2: { l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: 'done' } };
if (typeof writerMod.ensureLayer2Scheduled === 'function') {
  writerMod.ensureLayer2Scheduled(state);
} else {
  process.stdout.write('not_exported');
  process.exit(0);
}
process.stdout.write(state.layer2.l2_armed_at === null ? 'null' : String(state.layer2.l2_armed_at));
" 2>/dev/null)
    if [ "$out" = "null" ]; then
        pass "G24: l2_phase=done -> ensureLayer2Scheduled early-returns, l2_armed_at stays null"
    else
        fail "G24: l2_phase=done -> ensureLayer2Scheduled early-returns, l2_armed_at stays null (got: $out)"
    fi
}

run_g25() {
    require_source "$AGENTS_DIR/hooks/lib/supervisor-state-writer.js" "G25: l2_phase=frozen -> ensureLayer2Scheduled re-arms (l2_armed_at set, l2_phase=pending)" || return
    local out
    out=$(run_with_timeout 5 node -e "
const writerMod = require('$WRITER_NODE');
const state = { layer2: { l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: 'frozen', l2_cause: null, l2_retry_count: 0 } };
if (typeof writerMod.ensureLayer2Scheduled !== 'function') { process.stdout.write('not_exported'); process.exit(0); }
writerMod.ensureLayer2Scheduled(state);
const armedOk = typeof state.layer2.l2_armed_at === 'string' && state.layer2.l2_armed_at.length > 0;
const phaseOk = state.layer2.l2_phase === 'pending';
const retryOk = state.layer2.l2_retry_count === 0;
process.stdout.write((armedOk && phaseOk && retryOk) ? 'ok' : ('armed=' + state.layer2.l2_armed_at + ',phase=' + state.layer2.l2_phase + ',retry=' + state.layer2.l2_retry_count));
" 2>/dev/null)
    if [ "$out" = "ok" ]; then
        pass "G25: l2_phase=frozen -> ensureLayer2Scheduled re-arms (l2_armed_at set, l2_phase=pending)"
    else
        fail "G25: l2_phase=frozen -> ensureLayer2Scheduled re-arms (l2_armed_at set, l2_phase=pending) (got: $out)"
    fi
}

run_g26() {
    require_source "$AGENTS_DIR/hooks/lib/supervisor-state-writer.js" "G26: l2_phase=null -> ensureLayer2Scheduled sets l2_armed_at + l2_phase=pending" || return
    local out
    out=$(run_with_timeout 5 node -e "
const writerMod = require('$WRITER_NODE');
const state = { layer2: { l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null } };
if (typeof writerMod.ensureLayer2Scheduled !== 'function') { process.stdout.write('not_exported'); process.exit(0); }
writerMod.ensureLayer2Scheduled(state);
const ncOk = typeof state.layer2.l2_armed_at === 'string' && state.layer2.l2_armed_at.length > 0;
const phOk = state.layer2.l2_phase === 'pending';
process.stdout.write((ncOk && phOk) ? 'ok' : ('nc=' + state.layer2.l2_armed_at + ',ph=' + state.layer2.l2_phase));
" 2>/dev/null)
    if [ "$out" = "ok" ]; then
        pass "G26: l2_phase=null -> ensureLayer2Scheduled sets l2_armed_at + l2_phase=pending"
    else
        fail "G26: l2_phase=null -> ensureLayer2Scheduled sets l2_armed_at + l2_phase=pending (got: $out)"
    fi
}

run_g27() {
    require_source "$AGENTS_DIR/hooks/lib/supervisor-state-writer.js" "G27: l2_phase=pending + l2_armed_at already set -> ensureLayer2Scheduled no-op" || return
    local out
    out=$(run_with_timeout 5 node -e "
const writerMod = require('$WRITER_NODE');
const before = '2026-06-06T12:00:00.000Z';
const state = { layer2: { l2_armed_at: before, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: 'pending' } };
if (typeof writerMod.ensureLayer2Scheduled !== 'function') { process.stdout.write('not_exported'); process.exit(0); }
writerMod.ensureLayer2Scheduled(state);
process.stdout.write(state.layer2.l2_armed_at === before ? 'noop' : ('changed:' + state.layer2.l2_armed_at));
" 2>/dev/null)
    if [ "$out" = "noop" ]; then
        pass "G27: l2_phase=pending + l2_armed_at already set -> ensureLayer2Scheduled no-op"
    else
        fail "G27: l2_phase=pending + l2_armed_at already set -> ensureLayer2Scheduled no-op (got: $out)"
    fi
}

run_g28() {
    require_source "$AGENTS_DIR/hooks/lib/supervisor-state-writer.js" "G28: appendFinding with l2_phase=done -> finding appended, l2_armed_at stays null" || return
    local tmp out
    tmp="$(mktemp -d)"
    seed_state_raw "$tmp" "g28-sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: 'done' }"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const ok = w.appendFinding('g28-sid', { categories: ['workflow'], severity: 'notice', detail: 'd', reporter: 'r' });
process.stdout.write(ok ? 'ok' : 'fail');
" 2>/dev/null)
    local nc
    nc=$(read_l2_armed_at "$tmp" "g28-sid")
    rm -rf "$tmp"
    if [ "$out" = "ok" ] && [ "$nc" = "null" ]; then
        pass "G28: appendFinding with l2_phase=done -> finding appended, l2_armed_at stays null"
    else
        fail "G28: appendFinding with l2_phase=done -> finding appended, l2_armed_at stays null (out=$out, nc=$nc)"
    fi
}

run_g29() {
    require_source "$AGENTS_DIR/hooks/lib/supervisor-state-writer.js" "G29: writeLayer2State frozen->done -> rejected" || return
    local tmp out
    tmp="$(mktemp -d)"
    seed_state_raw "$tmp" "g29-sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: 'frozen' }"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const ok = w.writeLayer2State('g29-sid', { l2_phase: 'done' });
process.stdout.write(ok ? 'accepted' : 'rejected');
" 2>/dev/null)
    rm -rf "$tmp"
    if [ "$out" = "rejected" ]; then
        pass "G29: writeLayer2State frozen->done -> rejected"
    else
        fail "G29: writeLayer2State frozen->done -> rejected (got: $out)"
    fi
}

run_g30() {
    require_source "$AGENTS_DIR/hooks/lib/supervisor-state-writer.js" "G30: writeLayer2State done->pending -> rejected" || return
    local tmp out
    tmp="$(mktemp -d)"
    seed_state_raw "$tmp" "g30-sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: 'done' }"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const ok = w.writeLayer2State('g30-sid', { l2_phase: 'pending' });
process.stdout.write(ok ? 'accepted' : 'rejected');
" 2>/dev/null)
    rm -rf "$tmp"
    if [ "$out" = "rejected" ]; then
        pass "G30: writeLayer2State done->pending -> rejected"
    else
        fail "G30: writeLayer2State done->pending -> rejected (got: $out)"
    fi
}

run_g31() {
    require_source "$AGENTS_DIR/hooks/lib/supervisor-state-writer.js" "G31: writeLayer2State done->frozen -> accepted" || return
    local tmp out phase
    tmp="$(mktemp -d)"
    seed_state_raw "$tmp" "g31-sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: 'done' }"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const ok = w.writeLayer2State('g31-sid', { l2_phase: 'frozen' });
process.stdout.write(ok ? 'accepted' : 'rejected');
" 2>/dev/null)
    phase=$(read_l2_phase "$tmp" "g31-sid")
    rm -rf "$tmp"
    if [ "$out" = "accepted" ] && [ "$phase" = "frozen" ]; then
        pass "G31: writeLayer2State done->frozen -> accepted"
    else
        fail "G31: writeLayer2State done->frozen -> accepted (out=$out, phase=$phase)"
    fi
}

run_g32() {
    require_source "$AGENTS_DIR/hooks/lib/supervisor-state-writer.js" "G32: writeLayer2State frozen->frozen -> accepted (idempotent)" || return
    local tmp out phase
    tmp="$(mktemp -d)"
    seed_state_raw "$tmp" "g32-sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: 'frozen' }"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const ok = w.writeLayer2State('g32-sid', { l2_phase: 'frozen' });
process.stdout.write(ok ? 'accepted' : 'rejected');
" 2>/dev/null)
    phase=$(read_l2_phase "$tmp" "g32-sid")
    rm -rf "$tmp"
    if [ "$out" = "accepted" ] && [ "$phase" = "frozen" ]; then
        pass "G32: writeLayer2State frozen->frozen -> accepted (idempotent)"
    else
        fail "G32: writeLayer2State frozen->frozen -> accepted (idempotent) (out=$out, phase=$phase)"
    fi
}

run_g33() {
    require_source "$AGENTS_DIR/hooks/lib/supervisor-state-writer.js" "G33: writeLayer2State frozen + l2_armed_at set -> rejected" || return
    local tmp out
    tmp="$(mktemp -d)"
    seed_state_raw "$tmp" "g33-sid" "{ l2_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], l2_phase: null }"
    out=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const ok = w.writeLayer2State('g33-sid', { l2_phase: 'frozen', l2_armed_at: '2026-06-06T12:00:00Z' });
process.stdout.write(ok ? 'accepted' : 'rejected');
" 2>/dev/null)
    rm -rf "$tmp"
    if [ "$out" = "rejected" ]; then
        pass "G33: writeLayer2State frozen + l2_armed_at set -> rejected"
    else
        fail "G33: writeLayer2State frozen + l2_armed_at set -> rejected (got: $out)"
    fi
}

# ─── Runner ──────────────────────────────────────────────────────────────────

run_g20
run_g21
run_g22
run_g23
run_g24
run_g25
run_g26
run_g27
run_g28
run_g29
run_g30
run_g31
run_g32
run_g33

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
