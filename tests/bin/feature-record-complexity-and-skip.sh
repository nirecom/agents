#!/bin/bash
# Tests: bin/workflow/record-complexity-and-skip
# Tags: L2, workflow, speculative-skip, scope:issue-specific
# Security: N/A -- pure state-write logic; no external untrusted input
# Asserts the stdout purity contract of bin/workflow/record-complexity-and-skip:
# stdout MUST be exactly 'auto' or 'judgment' -- never RECORDED_* lines from sub-CLIs.

# L3 gap: whether clarify-intent / workflow-init invoke it at the right step with the
# right signals, and the real claude -p end-to-end run. Mitigation: the
# skill-orchestration category of bin/check-verification-gate.sh.

set -u

if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not available"
    exit 77
fi

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RCS_SCRIPT="$SCRIPT_CHECKOUT_ROOT/bin/workflow/record-complexity-and-skip"
STATEIO="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/state-io.js"
STATEIO_N="$(cygpath -m "$STATEIO" 2>/dev/null || echo "$STATEIO")"
READ_CE="$SCRIPT_CHECKOUT_ROOT/bin/workflow/read-complexity-evaluation"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e "alarm $secs; exec @ARGV" -- "$@"; fi
}

# Guard: if script doesn't exist yet, record RED failures for all cases
require_rcs() {
    if [ -x "$RCS_SCRIPT" ] || [ -f "$RCS_SCRIPT" ]; then return 0; fi
    fail "$1: record-complexity-and-skip not found at $RCS_SCRIPT (RED until /write-code)"
    return 1
}

TMPDIR_BASE="$(mktemp -d)"; readonly TMPDIR_BASE
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"
mkdir -p "$WORKFLOW_DIR"
WORKFLOW_DIR_N="$(cygpath -m "$WORKFLOW_DIR" 2>/dev/null || echo "$WORKFLOW_DIR")"
# Dual-pin (#1799): without WORKFLOW_PLANS_DIR the supervisor emitter still
# resolves the developer's real ~/.workflow-plans/ and appends there.
PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$PLANS_DIR"
PLANS_DIR_N="$(cygpath -m "$PLANS_DIR" 2>/dev/null || echo "$PLANS_DIR")"
# Top-level pin for every call below; the per-call assignments repeat the same values.
export WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" WORKFLOW_PLANS_DIR="$PLANS_DIR_N"

# Helper: read the derived aggregate level for a session. Anchored on the line
# start so the back-compat mode's `levels=<json>` line cannot satisfy it.
read_ce_level() {
    local sid="$1"
    WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" WORKFLOW_PLANS_DIR="$PLANS_DIR_N" run_with_timeout 10 node "$READ_CE" --session "$sid" 2>/dev/null | grep -oE '^level=[^ ]+' | head -1 || true
}

# Helper: read skip judgment for a session+target
read_skip_judgment() {
    local sid="$1" target="$2"
    WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" WORKFLOW_PLANS_DIR="$PLANS_DIR_N" run_with_timeout 10 node -e "
const io = require('$STATEIO_N');
try {
    const s = io.readState('$sid');
    const sj = s && s.skip_judgment && s.skip_judgment['$target'];
    console.log(sj ? JSON.stringify(sj) : 'null');
} catch(e) { console.log('null'); }
" 2>/dev/null || echo "null"
}

echo "=== RCS-1: auto path stdout purity (verdict=low, signals='') ==="
if require_rcs "RCS-1"; then
    SID="rcs1-$$"
    OUT=$(WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" WORKFLOW_PLANS_DIR="$PLANS_DIR_N" \
        run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --signals "" --target outline 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && [ "$OUT" = "auto" ]; then
        pass "RCS-1: stdout === 'auto' for 0-signal sonnet"
    else
        fail "RCS-1: expected 'auto', got rc=$RC out='$OUT'"
    fi
fi

echo "=== RCS-2: judgment path stdout purity (verdict=high, signals=S1-multi-file) ==="
if require_rcs "RCS-2"; then
    SID="rcs2-$$"
    OUT=$(WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" WORKFLOW_PLANS_DIR="$PLANS_DIR_N" \
        run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --signals "S1-multi-file" --target outline 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && [ "$OUT" = "judgment" ]; then
        pass "RCS-2: stdout === 'judgment' for high verdict"
    else
        fail "RCS-2: expected 'judgment', got rc=$RC out='$OUT'"
    fi
fi

echo "=== RCS-3: no RECORDED_* lines in stdout (max 1 line) ==="
if require_rcs "RCS-3"; then
    SID="rcs3-$$"
    OUT=$(WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" WORKFLOW_PLANS_DIR="$PLANS_DIR_N" \
        run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --signals "" --target outline 2>/dev/null)
    RC=$?
    LINE_COUNT=$(printf '%s' "$OUT" | wc -l | tr -d ' ')
    # wc -l counts newlines, so "auto" (no trailing newline) gives 0; "auto\n" gives 1.
    # Either 0 or 1 is acceptable; 2+ means RECORDED_* leaked.
    if [ "$RC" -eq 0 ] && [ "$LINE_COUNT" -le 1 ] && ! printf '%s' "$OUT" | grep -q 'RECORDED'; then
        pass "RCS-3: stdout has <=1 line, no RECORDED_* contamination"
    else
        fail "RCS-3: stdout lines=$LINE_COUNT or contains RECORDED_*; out='$OUT'"
    fi
fi

echo "=== RCS-4: auto path writes skip-judgment record ==="
if require_rcs "RCS-4"; then
    SID="rcs4-$$"
    WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" WORKFLOW_PLANS_DIR="$PLANS_DIR_N" \
        run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --signals "" --target outline >/dev/null 2>&1
    SJ=$(read_skip_judgment "$SID" "outline")
    if printf '%s' "$SJ" | grep -q '"all_conditions_met":true\|"all_conditions_met": true'; then
        pass "RCS-4: auto path wrote skip-judgment with all_conditions_met=true"
    else
        fail "RCS-4: skip-judgment not recorded or all_conditions_met not true; got: $SJ"
    fi
fi

echo "=== RCS-5: judgment path does NOT write skip-judgment ==="
if require_rcs "RCS-5"; then
    SID="rcs5-$$"
    WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" WORKFLOW_PLANS_DIR="$PLANS_DIR_N" \
        run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --signals "S1-multi-file" --target outline >/dev/null 2>&1
    SJ=$(read_skip_judgment "$SID" "outline")
    if [ "$SJ" = "null" ]; then
        pass "RCS-5: judgment path correctly does not write skip-judgment"
    else
        fail "RCS-5: skip-judgment was unexpectedly written on judgment path; got: $SJ"
    fi
fi

echo "=== RCS-6: complexity_evaluation always recorded (auto path) ==="
if require_rcs "RCS-6a"; then
    SID="rcs6a-$$"
    WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" WORKFLOW_PLANS_DIR="$PLANS_DIR_N" \
        run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --signals "" --target outline >/dev/null 2>&1
    CE=$(read_ce_level "$SID")
    if [ -n "$CE" ]; then
        pass "RCS-6a: complexity_evaluation recorded on auto path ($CE)"
    else
        fail "RCS-6a: complexity_evaluation NOT recorded on auto path"
    fi
fi

echo "=== RCS-6b: complexity_evaluation always recorded (judgment path) ==="
if require_rcs "RCS-6b"; then
    SID="rcs6b-$$"
    WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" WORKFLOW_PLANS_DIR="$PLANS_DIR_N" \
        run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --signals "S1-multi-file" --target outline >/dev/null 2>&1
    CE=$(read_ce_level "$SID")
    if [ -n "$CE" ]; then
        pass "RCS-6b: complexity_evaluation recorded on judgment path ($CE)"
    else
        fail "RCS-6b: complexity_evaluation NOT recorded on judgment path"
    fi
fi

echo "=== RCS-7: --target detail auto path records sd_c3 in skip-judgment ==="
if require_rcs "RCS-7"; then
    SID="rcs7-$$"
    OUT=$(WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" WORKFLOW_PLANS_DIR="$PLANS_DIR_N" \
        run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --signals "" --target detail 2>/dev/null)
    RC=$?
    SJ=$(read_skip_judgment "$SID" "detail")
    if [ "$RC" -eq 0 ] && [ "$OUT" = "auto" ] && printf '%s' "$SJ" | grep -q 'sd_c3'; then
        pass "RCS-7: --target detail auto path -> stdout=auto, skip-judgment has sd_c3"
    else
        fail "RCS-7: rc=$RC out='$OUT' sj=$SJ (expected auto stdout + sd_c3 in judgment)"
    fi
fi

echo "=== RCS-8: no root env var at all -> still records and answers ==="
# The script finds every sub-CLI beside its own path, so AGENTS_MAIN_ROOT and every
# retired root name can be absent. Asserted on stdout and both state records.
if require_rcs "RCS-8"; then
    SID="rcs8-$$"
    RCS8_UNSET=(-u AGENTS_MAIN_ROOT)
    while IFS= read -r RCS8_NAME; do
        RCS8_NAME="${RCS8_NAME%$'\r'}"
        [ -n "$RCS8_NAME" ] && RCS8_UNSET+=(-u "$RCS8_NAME")
    done < <(node "$SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy-build.js" --print-retired-env-names 2>/dev/null)
    OUT=$(run_with_timeout 15 env "${RCS8_UNSET[@]}" \
        WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" WORKFLOW_PLANS_DIR="$PLANS_DIR_N" \
        bash "$RCS_SCRIPT" --session "$SID" --signals "" --target outline 2>/dev/null)
    RC=$?
    SJ=$(read_skip_judgment "$SID" "outline")
    CE=$(read_ce_level "$SID")
    if [ "${#RCS8_UNSET[@]}" -gt 2 ] && [ "$RC" -eq 0 ] && [ "$OUT" = "auto" ] && [ -n "$CE" ] \
       && printf '%s' "$SJ" | grep -q '"all_conditions_met": *true'; then
        pass "RCS-8: no root env var -> stdout=auto, complexity and skip-judgment recorded"
    else
        fail "RCS-8: rc=$RC unset-args=${#RCS8_UNSET[@]} out='$OUT' ce='$CE' sj=$SJ"
    fi
fi

# --target names the skip-judgment key this run writes under. RCS-1/RCS-7 only
# ever pass a valid one, so a wrapper that accepts anything -- and writes a skip
# judgment under a key nothing reads, or swallows the following flag -- passes
# every case above. These rows pin the guard: usage exit 2, a diagnostic naming
# the flag, pure stdout, and no state written at all.
rcs_side_effects() {
    local sid="$1" ce sj_o sj_d
    ce=$(read_ce_level "$sid")
    sj_o=$(read_skip_judgment "$sid" "outline")
    sj_d=$(read_skip_judgment "$sid" "detail")
    printf 'ce=%s sj_outline=%s sj_detail=%s' "${ce:-none}" "$sj_o" "$sj_d"
}

echo "=== RCS-9: --target guard (empty / missing value / unknown / flag-as-value) ==="
if require_rcs "RCS-9"; then
    RCS9_LABELS="empty missing unknown flag-as-value traversal"
    for LABEL in $RCS9_LABELS; do
        case "$LABEL" in
            empty)         set -- --target "" ;;
            missing)       set -- --target ;;
            unknown)       set -- --target bogus-stage ;;
            flag-as-value) set -- --target --advance ;;
            traversal)     set -- --target ../../outline ;;
        esac
        SID="rcs9-$LABEL-$$"
        ERRF="$TMPDIR_BASE/rcs9-$LABEL.err"
        OUT=$(WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" \
            run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --signals "" "$@" 2>"$ERRF")
        RC=$?
        ERR=$(cat "$ERRF" 2>/dev/null || true)
        NAMES_TARGET=no
        printf '%s' "$ERR" | grep -q -- '--target' && NAMES_TARGET=yes
        SIDE=$(rcs_side_effects "$SID")
        VERDICT="rc=$RC out=[$OUT] err_names_target=$NAMES_TARGET $SIDE"
        WANT="rc=2 out=[] err_names_target=yes ce=none sj_outline=null sj_detail=null"
        if [ "$VERDICT" = "$WANT" ]; then
            pass "RCS-9-$LABEL: rejected with exit 2, a --target diagnostic, and zero side effects"
        else
            fail "RCS-9-$LABEL: want [$WANT], got [$VERDICT] (stderr: $ERR)"
        fi
    done
fi

echo "=== RCS-10: --target guard control (a valid target still works) ==="
if require_rcs "RCS-10"; then
    SID="rcs10-$$"
    OUT=$(WORKFLOW_STATE_DIR="$WORKFLOW_DIR_N" \
        run_with_timeout 15 bash "$RCS_SCRIPT" --session "$SID" --signals "" --target outline 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && [ "$OUT" = "auto" ]; then
        pass "RCS-10: --target outline is still accepted, so RCS-9's rejections measure validation"
    else
        fail "RCS-10: --target outline was rejected too (rc=$RC out='$OUT') -- RCS-9 proves nothing"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
