#!/usr/bin/env bash
# Tests: hooks/supervisor-guard.js (branch 2 cumSev=error l2_phase guard)
# Tags: supervisor, em-supervisor, layer2, hook, stop, fix-955, scope:issue-specific
# RED for issue #955.
#
# Validates: supervisor-guard.js branch (2) (cumulative_severity=error) must
# NOT block when l2_phase is "frozen" or "done" — those are terminal states and
# the session would otherwise be permanently stuck. Adds the
# `&& l2Phase !== "done" && l2Phase !== "frozen"` guard symmetric with
# branch (3) already at line 311.
#
# Out of scope (triage: NA per class members):
# - Branch (C3) WORKTREE_OFF proposal detection (line 289): already correctly handled by
#   tryIncrementFrozen() returning frozen:true for l2_phase=frozen. l2_phase=done is a
#   separate orthogonality concern not in this fix's scope.
#
# L3 gap (what this test does NOT catch):
# - hook registration in settings.json Stop hooks — if supervisor-guard.js is
#   not wired, blocking and unblocking behavior are both unobservable
# - real Claude Code transcript format differences
# Closest-to-action mitigation: hook-registration category in
#   bin/check-verification-gate.sh fires at WORKFLOW_USER_VERIFIED preflight.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/supervisor-guard.js"
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

# Seed state with explicit l2_phase value.
# phase_literal: pass "null" for null, or 'pending' / 'frozen' / 'done' (with single quotes for strings).
seed_state_phase() {
    local tmp="$1" sid="$2" phase_literal="$3" cum_sev_literal="$4"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.layer2 = {
  l2_armed_at: null,
  last_run_at: null,
  cumulative_severity: $cum_sev_literal,
  findings: [],
  l2_phase: $phase_literal,
  l2_cause: null,
  l2_retry_count: 0
};
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

# Run supervisor-guard.js with the given session id; capture stdout+rc.
run_guard() {
    local tmp="$1" sid="$2"
    echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null
}

# F1: l2_phase=null, cumulative_severity=error -> SHOULD block (normal case)
run_f1() {
    require_source "$HOOK" "F1: l2_phase=null + cumSev=error -> decision=block, exit 2" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state_phase "$tmp" "f1-sid" "null" "'error'"
    out=$(run_guard "$tmp" "f1-sid")
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && ( echo "$out" | grep -qi "block" ); then
        pass "F1: l2_phase=null + cumSev=error -> decision=block, exit 2"
    else
        fail "F1: l2_phase=null + cumSev=error -> decision=block, exit 2 (rc=$rc, out=$out)"
    fi
}

# F2: l2_phase=frozen, cumulative_severity=error -> SHOULD NOT block (bug fix)
# Also asserts that l2_retry_count is NOT incremented (the branch should be skipped entirely,
# not bailed via tryIncrementFrozen).
run_f2() {
    require_source "$HOOK" "F2: l2_phase=frozen + cumSev=error -> no block, exit 0" || return
    local tmp out rc retry_after
    tmp="$(mktemp -d)"
    seed_state_phase "$tmp" "f2-sid" "'frozen'" "'error'"
    out=$(run_guard "$tmp" "f2-sid")
    rc=$?
    retry_after=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('f2-sid');
process.stdout.write(String(st && st.layer2 ? st.layer2.l2_retry_count : -1));
" 2>/dev/null)
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! ( echo "$out" | grep -qi '"decision":"block"' ) && [ "$retry_after" = "0" ]; then
        pass "F2: l2_phase=frozen + cumSev=error -> no block, exit 0"
    else
        fail "F2: l2_phase=frozen + cumSev=error -> no block, exit 0 (rc=$rc, retry_count=$retry_after, out=$out)"
    fi
}

# F3: l2_phase=done, cumulative_severity=error -> SHOULD NOT block (symmetric)
run_f3() {
    require_source "$HOOK" "F3: l2_phase=done + cumSev=error -> no block, exit 0" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state_phase "$tmp" "f3-sid" "'done'" "'error'"
    out=$(run_guard "$tmp" "f3-sid")
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! ( echo "$out" | grep -qi '"decision":"block"' ); then
        pass "F3: l2_phase=done + cumSev=error -> no block, exit 0"
    else
        fail "F3: l2_phase=done + cumSev=error -> no block, exit 0 (rc=$rc, out=$out)"
    fi
}

# F4: l2_phase=pending, cumulative_severity=error -> SHOULD block (L2 in progress)
run_f4() {
    require_source "$HOOK" "F4: l2_phase=pending + cumSev=error -> decision=block, exit 2" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state_phase "$tmp" "f4-sid" "'pending'" "'error'"
    out=$(run_guard "$tmp" "f4-sid")
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && ( echo "$out" | grep -qi "block" ); then
        pass "F4: l2_phase=pending + cumSev=error -> decision=block, exit 2"
    else
        fail "F4: l2_phase=pending + cumSev=error -> decision=block, exit 2 (rc=$rc, out=$out)"
    fi
}

# F5: malformed or empty stdin -> SHOULD fail-open (exit 0, no block)
run_f5() {
    require_source "$HOOK" "F5: malformed stdin -> fail-open, exit 0" || return
    local tmp rc
    tmp="$(mktemp -d)"
    echo "not-json" | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "F5: malformed stdin -> fail-open, exit 0"
    else
        fail "F5: malformed stdin -> fail-open, exit 0 (rc=$rc)"
    fi
}

run_f1
run_f2
run_f3
run_f4
run_f5

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
