#!/usr/bin/env bash
# n9-duration-ledger-env.sh — ledger env hygiene, and a run that measures nothing.
# Tests: tests/run-all.sh, bin/lib/run-all-durations.sh, tests/feature-1832-run-all-parallel/_lib.sh
# Tags: tests, bin, parallel, ledger, TL2, scope:issue-specific

# WHY: the ledger cases SOURCE bin/lib/run-all-durations.sh into the test process, so its whole
# RUN_ALL_DUR_* family is live here. Without scrubbing, a developer's exported leftover would
# retarget or resize the child's ledger and quietly decide whether these tests pass.

# TL3 gap (what this test does NOT catch):
# - a variable the implementation adds later and nobody adds to FX_SCRUBBED_VARS
# - a shell profile that re-exports the variable inside the child itself
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category pwsh-required.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "n9-duration-ledger-env"

DUR_LIB_REL="bin/lib/run-all-durations.sh"
DUR_LIB="$FX_REPO_ROOT/$DUR_LIB_REL"

dur_missing() {
    [ -f "$DUR_LIB" ] && return 1
    fx_fail "$1 (implementation missing: $DUR_LIB_REL)"
    return 0
}

UNMEASURED=99
if [ -f "$DUR_LIB" ]; then
    # shellcheck source=/dev/null
    . "$DUR_LIB" 2>/dev/null || true
    UNMEASURED="${RUN_ALL_DUR_TIER_UNMEASURED:-99}"
fi

plan_tier() {
    awk -F'\t' -v b="$2" \
        '$1 == "plan" { n = split($4, a, /[\/\\]/); if (a[n] == b) { print $5; exit } }' "$1"
}

V="$(fx_new_root)"
fx_add_dummy "$V" v1 --sleep 2
fx_add_dummy "$V" v2 --sleep 8
V_OUT="$FX_TMP_ROOT/v.out"; V_ERR="$FX_TMP_ROOT/v.err"
VP_OUT="$FX_TMP_ROOT/vp.out"; VP_ERR="$FX_TMP_ROOT/vp.err"

FX_LEDGER_KEEP=1
fx_ledger_clear
fx_exec "$V" 120 "$V_OUT" "$V_ERR" -j 2 --all
V_EXEC="$(fx_contract_field "$V_OUT" EXECUTED)"

if [ "$V_EXEC" = "2" ]; then
    fx_pass "N34d. the fixture is real: the warm-up measured both dummies"
else
    fx_fail "N34d. the fixture is not usable — want EXECUTED=2 in the warm-up, got ${V_EXEC:-absent}"
    fx_show_tail "$V_ERR" 6
fi

# ===========================================================================
# N34a — leaked ledger internals must not reach the child
# ===========================================================================
# A repo id and host token from THIS process point at a different ledger identity. If they
# reached the child, every lookup would miss and the plan would silently fall back to
# unmeasured — a green suite that proved nothing about ordering.
export RUN_ALL_DUR_REPO_ID="ZZZZZZZZZZZZZZZZ"
export RUN_ALL_DUR_HOST_TOKEN="ZZZZZZZZZZZZZZZZ"
export RUN_ALL_DUR_SEGMENT="$FX_TMP_ROOT/not-a-segment.log"
export RUN_ALL_DUR_KEEP_SEGMENTS="1"
fx_exec "$V" 60 "$VP_OUT" "$VP_ERR" --print-plan --all
A_RC=$?
unset RUN_ALL_DUR_REPO_ID RUN_ALL_DUR_HOST_TOKEN RUN_ALL_DUR_SEGMENT RUN_ALL_DUR_KEEP_SEGMENTS
A_T1="$(plan_tier "$VP_OUT" v1.sh)"
A_T2="$(plan_tier "$VP_OUT" v2.sh)"

if dur_missing "N34a. exported RUN_ALL_DUR_* leftovers do not change the child's plan"; then :
elif [ "$A_RC" -eq 0 ] && [ "$A_T1" = "1" ] && [ "$A_T2" = "3" ]; then
    fx_pass "N34a. with a hostile repo id, host token, segment and retention exported, the child still reported v1=1 v2=3"
else
    fx_fail "N34a. want exit 0 with v1 tier 1 and v2 tier 3 despite the exported leftovers, got exit $A_RC v1='${A_T1:-absent}' v2='${A_T2:-absent}'"
    fx_show_tail "$VP_ERR" 6
fi

# ===========================================================================
# N34c — RUN_ALL_DURATIONS_LIB stays caller intent, in both directions
# ===========================================================================
# The scrub must not swallow the one ledger variable a case legitimately pins (n2- uses it to
# simulate a missing library). Both directions are asserted in one pair: pinned then unpinned.
export RUN_ALL_DURATIONS_LIB="$FX_TMP_ROOT/no-such-durations-lib.sh"
fx_exec "$V" 60 "$VP_OUT" "$VP_ERR" --print-plan --all
C_RC=$?
C_99="$(awk -F'\t' -v u="$UNMEASURED" '$1 == "plan" && $5 == u { n++ } END { print n + 0 }' "$VP_OUT")"
unset RUN_ALL_DURATIONS_LIB

fx_exec "$V" 60 "$VP_OUT" "$VP_ERR" --print-plan --all
C_T1="$(plan_tier "$VP_OUT" v1.sh)"
C_T2="$(plan_tier "$VP_OUT" v2.sh)"
FX_LEDGER_KEEP=0

if dur_missing "N34c. RUN_ALL_DURATIONS_LIB is forwarded when set and absent when unset"; then :
elif [ "$C_RC" -eq 0 ] && [ "$C_99" = "2" ] && [ "$C_T1" = "1" ] && [ "$C_T2" = "3" ]; then
    fx_pass "N34c. pinning a missing library forced both tiers to $UNMEASURED, and unsetting it restored v1=1 v2=3"
else
    fx_fail "N34c. want exit 0 with 2 rows at $UNMEASURED while pinned, then v1=1 v2=3 once unset, got exit $C_RC at-unmeasured=$C_99 v1='${C_T1:-absent}' v2='${C_T2:-absent}'"
fi

# ===========================================================================
# N36 — a run that executes nothing must not create a ledger at all
# ===========================================================================
# Writer init is lazy (first completion). A run with no work, like --print-plan, is
# read-only, so an empty durations/ directory here would mean the writer initialises eagerly.
Z="$(fx_new_root)"
fx_add_dummy "$Z" z1
Z_OUT="$FX_TMP_ROOT/z.out"; Z_ERR="$FX_TMP_ROOT/z.err"
fx_exec "$Z" 60 "$Z_OUT" "$Z_ERR" "$(fx_tests_dir "$Z")/nosuch-*.sh"
Z_RC=$?
Z_EXEC="$(fx_contract_field "$Z_OUT" EXECUTED)"
Z_DIR=absent
[ -e "$(fx_ledger_dir)" ] && Z_DIR=present

if [ "$Z_RC" -eq 0 ] && [ "$Z_EXEC" = "0" ] && [ "$Z_DIR" = "absent" ]; then
    fx_pass "N36. a pattern matching no test exited 0 with EXECUTED=0 and left no durations/ directory"
else
    fx_fail "N36. want exit 0, EXECUTED=0 and no durations/ directory, got exit $Z_RC EXECUTED=${Z_EXEC:-absent} durations=$Z_DIR"
    fx_show_tail "$Z_ERR" 6
fi

# ===========================================================================
# N34b — the fixture's own env contract, variable by variable
# ===========================================================================
# N34a proves the outcome for four variables. This table is the mechanical proof for the
# whole family, and the two `forward` rows stop "scrub everything" from passing it.
for FXV in $FX_SCRUBBED_VARS; do
    eval "export $FXV=fxprobe"
done
export RUN_ALL_DURATIONS_LIB=fxprobe-lib
RUN_ALL_REAP=fifo
ARGS=" $(fx_control_args) "

ENV_BAD=""
while IFS='|' read -r name want; do
    [ -n "$name" ] || continue
    has_u=0; has_val=0
    case "$ARGS" in *" -u $name "*) has_u=1 ;; esac
    case "$ARGS" in *" $name="*) has_val=1 ;; esac
    case "$want" in
        scrub)   [ "$has_u" = "1" ] && [ "$has_val" = "0" ] || ENV_BAD="$ENV_BAD $name(want=scrub -u=$has_u forwarded=$has_val)" ;;
        forward) [ "$has_val" = "1" ] || ENV_BAD="$ENV_BAD $name(want=forward -u=$has_u forwarded=$has_val)" ;;
    esac
done <<TABLE
$(for FXV in $FX_SCRUBBED_VARS; do printf '%s|scrub\n' "$FXV"; done)
RUN_ALL_DURATIONS_LIB|forward
RUN_ALL_REAP|forward
TABLE

FXN="$(printf '%s\n' $FX_SCRUBBED_VARS | grep -c .)"
for FXV in $FX_SCRUBBED_VARS; do
    unset "$FXV"
done
unset RUN_ALL_DURATIONS_LIB RUN_ALL_REAP

if [ "$FXN" -ge 10 ] && [ -z "$ENV_BAD" ]; then
    fx_pass "N34b. all $FXN ledger tuning/output variables are scrubbed while RUN_ALL_DURATIONS_LIB and RUN_ALL_REAP are still forwarded"
else
    fx_fail "N34b. env contract violations (scrub list size $FXN):${ENV_BAD:- none}"
fi

fx_finish
