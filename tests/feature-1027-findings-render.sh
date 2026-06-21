#!/bin/bash
# tests/feature-1027-findings-render.sh
# Tests: hooks/lib/supervisor-findings-render.js
# Tags: supervisor, em-supervisor, l2-findings, scope:issue-specific
# Tests for issue #1027 — formatLayer2Findings renderer (NEW module).
#
# # L3 gap
# Pure unit module — no host dependencies. L3 not required.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

RENDER_SRC="$AGENTS_DIR/hooks/lib/supervisor-findings-render.js"
RENDER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-findings-render.js"

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

OPTS_JS="{ sessionId: 'sid-r1', workflowSessionId: 'wsid-r1', stateFilePath: '/tmp/state.json', supervisorPath: '/tmp/supervisor' }"

# --- R1: zero findings -> null ---------------------------------------------
run_r1() {
    require_source "$RENDER_SRC" "R1: zero findings -> null" || return
    local out rc
    out="$(run_with_timeout 10 node -e "
const r = require('$RENDER_NODE');
const v = r.formatLayer2Findings([], $OPTS_JS);
if (v === null) { console.log('NULL'); } else { console.log('NOT_NULL:' + typeof v); }
" 2>/dev/null)"
    rc=$?
    if [ "$rc" = "0" ] && [ "$out" = "NULL" ]; then
        pass "R1: zero findings -> null"
    else
        fail "R1: zero findings -> null (rc=$rc, out=$out)"
    fi
}

# --- R2: 1 warning + 2 notice -> header + warning line + notices-count ------
run_r2() {
    require_source "$RENDER_SRC" "R2: 1 warning + 2 notice -> header + warning + notices count" || return
    local out rc
    out="$(run_with_timeout 10 node -e "
const r = require('$RENDER_NODE');
const findings = [
  { categories:['code'], severity:'warning', detail:'wdetail', reporter:'wrep' },
  { categories:['code'], severity:'notice', detail:'n1', reporter:'r1' },
  { categories:['code'], severity:'notice', detail:'n2', reporter:'r2' },
];
const v = r.formatLayer2Findings(findings, $OPTS_JS);
if (typeof v !== 'string') { console.error('not string'); process.exit(2); }
process.stdout.write(v);
" 2>/dev/null)"
    rc=$?
    if [ "$rc" = "0" ] && \
       echo "$out" | grep -qi "warning" && \
       echo "$out" | grep -qi "wdetail" && \
       echo "$out" | grep -qE "notice.*2|2.*notice"; then
        pass "R2: 1 warning + 2 notice -> warning line + notices-count line"
    else
        fail "R2: warning+notice rendering (rc=$rc, out=$out)"
    fi
}

# --- R3: 1 error + 0 notice -> header + error line, no notices line ---------
run_r3() {
    require_source "$RENDER_SRC" "R3: 1 error + 0 notice -> error line, no notices line" || return
    local out rc
    out="$(run_with_timeout 10 node -e "
const r = require('$RENDER_NODE');
const findings = [
  { categories:['code'], severity:'error', detail:'edetail', reporter:'erep' },
];
const v = r.formatLayer2Findings(findings, $OPTS_JS);
if (typeof v !== 'string') process.exit(2);
process.stdout.write(v);
" 2>/dev/null)"
    rc=$?
    if [ "$rc" = "0" ] && \
       echo "$out" | grep -qi "error" && \
       echo "$out" | grep -qi "edetail" && \
       ! echo "$out" | grep -qiE "notice"; then
        pass "R3: 1 error + 0 notice -> error line, no notice text"
    else
        fail "R3: error-only rendering (rc=$rc, out=$out)"
    fi
}

# --- R4: 0 warning/error + 3 notice -> header + notices-count, no per-finding -
run_r4() {
    require_source "$RENDER_SRC" "R4: 3 notice -> notices-count only, no per-finding block" || return
    local out rc
    out="$(run_with_timeout 10 node -e "
const r = require('$RENDER_NODE');
const findings = [
  { categories:['code'], severity:'notice', detail:'n_a_unique', reporter:'r1' },
  { categories:['code'], severity:'notice', detail:'n_b_unique', reporter:'r2' },
  { categories:['code'], severity:'notice', detail:'n_c_unique', reporter:'r3' },
];
const v = r.formatLayer2Findings(findings, $OPTS_JS);
if (typeof v !== 'string') process.exit(2);
process.stdout.write(v);
" 2>/dev/null)"
    rc=$?
    # All 3 notice detail strings should NOT each appear (no per-finding block);
    # the notices-count line should be present.
    if [ "$rc" = "0" ] && \
       echo "$out" | grep -qE "notice.*3|3.*notice" && \
       ! ( echo "$out" | grep -q "n_a_unique" && echo "$out" | grep -q "n_b_unique" && echo "$out" | grep -q "n_c_unique" ); then
        pass "R4: 3 notice -> notices-count only (no per-finding block)"
    else
        fail "R4: 3 notice rendering (rc=$rc, out=$out)"
    fi
}

# --- R5: header/footer fields appear verbatim from opts ---------------------
run_r5() {
    require_source "$RENDER_SRC" "R5: opts fields appear verbatim in output" || return
    local out rc
    out="$(run_with_timeout 10 node -e "
const r = require('$RENDER_NODE');
const findings = [
  { categories:['code'], severity:'warning', detail:'wd', reporter:'wr' },
];
const opts = { sessionId: 'SID_TOKEN_X', workflowSessionId: 'WSID_TOKEN_Y', stateFilePath: '/p/state.json', supervisorPath: '/p/supervisor' };
const v = r.formatLayer2Findings(findings, opts);
if (typeof v !== 'string') process.exit(2);
process.stdout.write(v);
" 2>/dev/null)"
    rc=$?
    if [ "$rc" = "0" ] && \
       echo "$out" | grep -qF "SID_TOKEN_X" && \
       echo "$out" | grep -qF "WSID_TOKEN_Y" && \
       echo "$out" | grep -qF "/p/state.json" && \
       echo "$out" | grep -qF "/p/supervisor"; then
        pass "R5: sessionId, workflowSessionId, stateFilePath, supervisorPath appear verbatim"
    else
        fail "R5: opts fields not present in output (rc=$rc, out=$out)"
    fi
}

# --- R6: workflowSessionId=null -> rendered output contains "UNAVAILABLE" ----
run_r6() {
    require_source "$RENDER_SRC" "R6: workflowSessionId=null -> UNAVAILABLE in output" || return
    local out rc
    out="$(run_with_timeout 10 node -e "
const r = require('$RENDER_NODE');
const findings = [
  { categories:['code'], severity:'warning', detail:'wd6', reporter:'wr6' },
];
const opts = { sessionId: 'sid-r6', workflowSessionId: null, stateFilePath: '/tmp/state.json', supervisorPath: '/tmp/supervisor' };
const v = r.formatLayer2Findings(findings, opts);
if (typeof v !== 'string') process.exit(2);
process.stdout.write(v);
" 2>/dev/null)"
    rc=$?
    if [ "$rc" = "0" ] && echo "$out" | grep -qF "UNAVAILABLE"; then
        pass "R6: workflowSessionId=null -> output contains UNAVAILABLE"
    else
        fail "R6: workflowSessionId=null (rc=$rc, out=$out)"
    fi
}

# --- R7: 2 warning-severity findings -> output contains [1] and [2] -----------
run_r7() {
    require_source "$RENDER_SRC" "R7: 2 warning findings -> [1] and [2] entries" || return
    local out rc
    out="$(run_with_timeout 10 node -e "
const r = require('$RENDER_NODE');
const findings = [
  { categories:['code'], severity:'warning', detail:'wa', reporter:'r1' },
  { categories:['test'], severity:'warning', detail:'wb', reporter:'r2' },
];
const v = r.formatLayer2Findings(findings, $OPTS_JS);
if (typeof v !== 'string') process.exit(2);
process.stdout.write(v);
" 2>/dev/null)"
    rc=$?
    if [ "$rc" = "0" ] && \
       echo "$out" | grep -qF "[1]" && \
       echo "$out" | grep -qF "[2]" && \
       echo "$out" | grep -qF "wa" && \
       echo "$out" | grep -qF "wb"; then
        pass "R7: 2 warning findings -> numbered [1] and [2] entries present"
    else
        fail "R7: 2 warning findings numbering (rc=$rc, out=$out)"
    fi
}

run_r1
run_r2
run_r3
run_r4
run_r5
run_r6
run_r7

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
