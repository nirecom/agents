#!/bin/bash
# tests/fix-supervisor-c2-label-891-892-label.sh
# Tests: hooks/supervisor-guard.js, agents/supervisor.md
# Tags: supervisor, em-supervisor, layer2, fix
# RED for #929 (label rename "C2 scheduled-review" -> non-numeric "scheduled-review");
# the "C2 escape-hatch use" absence checks (from #879) are preserved and stay GREEN.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/supervisor-guard.js"
HOOK_NODE="$_AGENTS_DIR_NODE/hooks/supervisor-guard.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
SUPERVISOR_MD="$AGENTS_DIR/agents/supervisor.md"

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
st.alert = $layer2_json;
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

run_l1a() {
    local label="L1-a: hooks/supervisor-guard.js uses non-numeric 'scheduled-review' (no C2 prefix)"
    if grep -q 'scheduled-review' "$HOOK" && ! grep -q 'C2 scheduled-review' "$HOOK"; then
        pass "$label"
    else
        fail "$label"
    fi
}

run_l1b() {
    local label="L1-b: hooks/supervisor-guard.js does NOT contain 'C2 escape-hatch use'"
    if grep -q 'C2 escape-hatch use' "$HOOK"; then
        fail "$label"
    else
        pass "$label"
    fi
}

run_l1c() {
    local label="L1-c: agents/supervisor.md uses non-numeric 'scheduled-review' (no C2 prefix)"
    if grep -q 'scheduled-review' "$SUPERVISOR_MD" && ! grep -q 'C2 scheduled-review' "$SUPERVISOR_MD"; then
        pass "$label"
    else
        fail "$label"
    fi
}

run_l1d() {
    local label="L1-d: agents/supervisor.md does NOT contain 'C2 escape-hatch use'"
    if grep -q 'C2 escape-hatch use' "$SUPERVISOR_MD"; then
        fail "$label"
    else
        pass "$label"
    fi
}

run_l1e() {
    local label="L1-e: block-reason interpolates 'Alert mode review required (scheduled review)'"
    local tmp out rc
    tmp="$(mktemp -d)"
    seed_state "$tmp" "l1e-sid" "{ alert_armed_at: '2026-06-06T12:00:00Z', last_run_at: null, cumulative_severity: null, findings: [], alert_phase: 'pending' }"
    out=$(echo '{"stop_hook_active":false,"session_id":"l1e-sid","transcript_path":""}' \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 2 ] && ( echo "$out" | grep -q 'Alert mode review required (scheduled review)' ) && ! ( echo "$out" | grep -q 'C2 scheduled review' ); then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

run_l1a
run_l1b
run_l1c
run_l1d
run_l1e

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
