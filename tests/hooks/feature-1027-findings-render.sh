#!/bin/bash
# tests/hooks/feature-1027-findings-render.sh
# Tests: hooks/lib/supervisor-findings-render.js
# Tags: supervisor, em-supervisor, l2-findings, scope:issue-specific
# Tests for issue #1027 — formatLayer2Findings renderer (NEW module).
#
# # L3 gap
# Pure unit module — no host dependencies. L3 not required.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

if command -v cygpath >/dev/null 2>&1; then
    _SCRIPT_CHECKOUT_ROOT_NODE="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"
else
    _SCRIPT_CHECKOUT_ROOT_NODE="$SCRIPT_CHECKOUT_ROOT"
fi

RENDER_SRC="$SCRIPT_CHECKOUT_ROOT/hooks/lib/supervisor-findings-render.js"
RENDER_NODE="$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/lib/supervisor-findings-render.js"

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
const opts = { sessionId: 'SID_TOKEN_X', workflowSessionId: 'WSID_TOKEN_Y', stateFilePath: '/tmp/state-r5.json', supervisorPath: '/tmp/supervisor-r5' };
const v = r.formatLayer2Findings(findings, opts);
if (typeof v !== 'string') process.exit(2);
process.stdout.write(v);
" 2>/dev/null)"
    rc=$?
    if [ "$rc" = "0" ] && \
       echo "$out" | grep -qF "SID_TOKEN_X" && \
       echo "$out" | grep -qF "WSID_TOKEN_Y" && \
       echo "$out" | grep -qF "/tmp/state-r5.json" && \
       echo "$out" | grep -qF "/tmp/supervisor-r5"; then
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

# --- R8: default mode includes reporter= in output ---
# RED: fails until supervisor-findings-render.js adds reporter field to finding lines.
run_r8() {
    require_source "$RENDER_SRC" "R8: default mode includes reporter= field" || return
    local out rc
    out="$(run_with_timeout 10 node -e "
const r = require('$RENDER_NODE');
const findings = [
  { categories:['code'], severity:'warning', detail:'wd8', reporter:'agent-r8' },
];
const v = r.formatLayer2Findings(findings, $OPTS_JS);
if (typeof v !== 'string') process.exit(2);
process.stdout.write(v);
" 2>/dev/null)"
    rc=$?
    if [ "$rc" = "0" ] && echo "$out" | grep -qF "reporter=agent-r8"; then
        pass "R8: default mode includes reporter=agent-r8 in finding line"
    else
        fail "R8: reporter= field missing from default-mode output (rc=$rc, out=$out)"
    fi
}

# --- R9/R10 (#2100 H5, SF-M1..SF-M3): alert model line in full mode only ------
R9_WORK="$(mktemp -d)"
trap 'rm -rf "$R9_WORK"' EXIT
mkdir -p "$R9_WORK/cfg" "$R9_WORK/neutral" "$R9_WORK/wf" "$R9_WORK/plans"

# r9_render <env-content> <opts-extra-js> — formatLayer2Findings under a fixture .env.
r9_render() {
    local cfg="$R9_WORK/cfg"
    printf '%b' "$1" > "$cfg/.env"
    command -v cygpath >/dev/null 2>&1 && cfg="$(cygpath -m "$cfg")"
    (
        cd "$R9_WORK/neutral" || exit 1
        run_with_timeout 10 env -u REVIEWER_MODEL -u ALERT_MODEL -u PRODUCER_HIGH_MODEL \
            -u PRODUCER_LOW_MODEL -u CLAUDE_PROJECT_DIR \
            -u CLAUDE_CODE_SESSION_ID AGENTS_MAIN_ROOT="$cfg" \
            WORKFLOW_STATE_DIR="$R9_WORK/wf" WORKFLOW_PLANS_DIR="$R9_WORK/plans" node -e "
const r = require('$RENDER_NODE');
const findings = [
  { categories:['code'], severity:'error', detail:'r9-detail', reporter:'r9' },
  { categories:['code'], severity:'notice', detail:'r9-notice', reporter:'r9' },
];
const v = r.formatLayer2Findings(findings, Object.assign($OPTS_JS, $2));
process.stdout.write(String(v));
"
    ) 2>/dev/null
}

# r9_after <text> — the line right after the full-mode spawn instruction.
r9_after() {
    printf '%s\n' "$1" | awk 'hit { print; exit } /^Recommended action: review and address per agents\/supervisor[.]md / { hit = 1 }'
}

r9_expect() {
    local label="$1" out="$2" alias="$3" want got n
    want="Subagent model: pass model: \"$alias\" to the Agent tool."
    got="$(r9_after "$out")"
    n="$(printf '%s\n' "$out" | grep -c '^Subagent model:')"
    if [ "$got" = "$want" ] && [ "$n" = "1" ]; then
        pass "$label"
    else
        fail "$label (line after spawn: '$got'; want '$want'; model lines=$n)"
    fi
}

run_r9() {
    require_source "$RENDER_SRC" "R9: full-mode alert model line" || return
    local out
    out="$(r9_render 'ALERT_MODEL=haiku\nREVIEWER_MODEL=opus\n' '{}')"
    r9_expect "R9 SF-M1: ALERT_MODEL=haiku reaches the full-mode model line" "$out" haiku
    out="$(r9_render 'REVIEWER_MODEL=haiku\n' '{}')"
    r9_expect "R9 SF-M1 swap: REVIEWER_MODEL alone leaves the alert default (sonnet)" "$out" sonnet
    out="$(r9_render 'ALERT_MODEL=gpt-r9leak\n' '{}')"
    r9_expect "R9 SF-M2: invalid ALERT_MODEL falls back to sonnet" "$out" sonnet
    if printf '%s' "$out" | grep -q 'r9leak'; then
        fail "R9 SF-M2: invalid value echoed into output"
    elif ! printf '%s' "$out" | grep -q '^Recommended action: review and address'; then
        fail "R9 SF-M2: full-mode render missing (out=$out)"
    else
        pass "R9 SF-M2: invalid value withheld from output"
    fi
}

# SF-M3 negative control: summaryOnly / actionableOnly carry no spawn line.
run_r10() {
    require_source "$RENDER_SRC" "R10: summary/actionable modes carry no model line" || return
    local out mode
    for mode in summaryOnly actionableOnly; do
        out="$(r9_render 'ALERT_MODEL=haiku\n' "{ $mode: true }")"
        if printf '%s' "$out" | grep -q '^\[EM Supervisor\]' && ! printf '%s' "$out" | grep -q 'Subagent model:'; then
            pass "R10 SF-M3: $mode output has no Subagent model: line"
        else
            fail "R10 SF-M3: $mode output unexpected (out=$out)"
        fi
    done
}

case_begin "zero-findings-null" "hooks/lib/supervisor-findings-render.js"
run_r1
case_end

case_begin "warning-notice-rendering" "hooks/lib/supervisor-findings-render.js"
run_r2
case_end

case_begin "error-no-notice-rendering" "hooks/lib/supervisor-findings-render.js"
run_r3
case_end

case_begin "notices-only-count-line" "hooks/lib/supervisor-findings-render.js"
run_r4
case_end

case_begin "opts-fields-verbatim" "hooks/lib/supervisor-findings-render.js"
run_r5
case_end

case_begin "workflow-session-id-null-unavailable" "hooks/lib/supervisor-findings-render.js"
run_r6
case_end

case_begin "two-warnings-numbered" "hooks/lib/supervisor-findings-render.js"
run_r7
case_end

case_begin "reporter-field-in-output" "hooks/lib/supervisor-findings-render.js"
run_r8
case_end

case_begin "alert-model-line-full-mode" "hooks/lib/supervisor-findings-render.js"
run_r9
case_end

case_begin "summary-actionable-no-model-line" "hooks/lib/supervisor-findings-render.js"
run_r10
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
