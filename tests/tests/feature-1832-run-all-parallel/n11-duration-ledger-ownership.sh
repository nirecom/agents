#!/usr/bin/env bash
# n11-duration-ledger-ownership.sh — one process, one segment, proven per file.
# Tests: bin/lib/run-all-durations.sh, tests/run-all.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, ledger, concurrency, TL2, scope:issue-specific
# WHY: sibling N10 counts segments and records in aggregate, so a writer that funnelled BOTH
# runners' records into one file and left the other empty would still pass it. Here each runner
# owns a disjoint key set, so ownership is checked file by file: every segment on disk must be
# non-empty and must carry records from exactly one runner. That is the property append
# atomicity is never relied upon for.
# TL3 gap: more than two real runners on a contended multi-core host — mitigated at
# WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category pwsh-required.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "n11-duration-ledger-ownership"

DUR_LIB_REL="bin/lib/run-all-durations.sh"
DUR_LIB="$FX_REPO_ROOT/$DUR_LIB_REL"

dur_missing() {
    [ -f "$DUR_LIB" ] && return 1
    fx_fail "$1 (implementation missing: $DUR_LIB_REL)"
    return 0
}

# Key sets are disjoint by their first character, so the owner of a record is readable
# from the record itself. u* comes from runner U, v* from runner V.
U="$(fx_new_root)"
fx_add_dummy "$U" u1 --sleep 1
fx_add_dummy "$U" u2 --sleep 2
fx_add_dummy "$U" u3 --sleep 1
V="$(fx_new_root)"
fx_add_dummy "$V" v1 --sleep 1
fx_add_dummy "$V" v2 --sleep 2
fx_add_dummy "$V" v3 --sleep 1

U_OUT="$FX_TMP_ROOT/u.out"; U_ERR="$FX_TMP_ROOT/u.err"
V_OUT="$FX_TMP_ROOT/v.out"; V_ERR="$FX_TMP_ROOT/v.err"

FX_LEDGER_KEEP=1
fx_ledger_clear
fx_exec_bg "$U" "$U_OUT" "$U_ERR" -j 3 --all
PID_U="$FX_BG_PID"
fx_exec_bg "$V" "$V_OUT" "$V_ERR" -j 3 --all
PID_V="$FX_BG_PID"
wait "$PID_U" 2>/dev/null
wait "$PID_V" 2>/dev/null
FX_LEDGER_KEEP=0

U_EXEC="$(fx_contract_field "$U_OUT" EXECUTED)"
V_EXEC="$(fx_contract_field "$V_OUT" EXECUTED)"

# owners_of <segment> — the sorted, unique owner letters present in that file.
owners_of() {
    awk -F'|' 'NF == 3 { n = split($3, a, /[\/\\]/); print substr(a[n], 1, 1) }' "$1" |
        LC_ALL=C sort -u | tr -d '\n'
}

SEGS=0; EMPTY=0; SHARED=0; OWNER_SET=""
for f in "$(fx_ledger_dir)"/dur.*; do
    [ -f "$f" ] || continue
    SEGS=$((SEGS + 1))
    n="$(grep -c '' "$f" 2>/dev/null || true)"
    [ "${n:-0}" -eq 0 ] && { EMPTY=$((EMPTY + 1)); continue; }
    o="$(owners_of "$f")"
    if [ "${#o}" -ne 1 ]; then
        SHARED=$((SHARED + 1))
    else
        OWNER_SET="$OWNER_SET$o"
    fi
done
OWNER_SET="$(printf '%s' "$OWNER_SET" | fold -w1 | LC_ALL=C sort -u | tr -d '\n')"

LINES="$(fx_ledger_lines)"
KEYS="$(fx_ledger_cat | awk -F'|' 'NF == 3 { k[$3] = 1 } END { c = 0; for (x in k) c++; print c + 0 }')"

# ===========================================================================
# N39 — the fixture actually put two concurrent runners on the same ledger
# ===========================================================================
if [ "$U_EXEC" = "3" ] && [ "$V_EXEC" = "3" ]; then
    fx_pass "N39a. the fixture is real: both concurrent runners executed 3 dummies each"
else
    fx_fail "N39a. the fixture is not usable — want EXECUTED=3 from each runner, got U=${U_EXEC:-absent} V=${V_EXEC:-absent}"
    fx_show_tail "$U_ERR" 6
    fx_show_tail "$V_ERR" 6
fi

if dur_missing "N39. every segment is non-empty and owned by exactly one runner"; then :
elif [ "$SEGS" = "2" ] && [ "$EMPTY" = "0" ] && [ "$SHARED" = "0" ] && \
     [ "$OWNER_SET" = "uv" ] && [ "$LINES" = "6" ] && [ "$KEYS" = "6" ]; then
    fx_pass "N39. 2 segments, neither empty, each carrying exactly one runner's keys (owners: $OWNER_SET) over 6 distinct records"
else
    fx_fail "N39. want segments=2 empty=0 shared-owner-segments=0 owners='uv' lines=6 keys=6, got segments=$SEGS empty=$EMPTY shared=$SHARED owners='$OWNER_SET' lines=$LINES keys=$KEYS"
fi

# ===========================================================================
# N40 — the owner check can actually fail
# ===========================================================================
# owners_of returning a fixed single letter would make N39 vacuous. This plants one
# segment holding both key families and asserts the same helper reports two owners.
if dur_missing "N40. the ownership helper reports a mixed segment as mixed"; then :
else
    MIX="$FX_TMP_ROOT/mixed-segment.log"
    {
        printf 'AAAAAAAAAAAAAAAA|1|tests/u9.sh\n'
        printf 'AAAAAAAAAAAAAAAA|2|tests/v9.sh\n'
    } > "$MIX"
    MIX_O="$(owners_of "$MIX")"
    if [ "$MIX_O" = "uv" ]; then
        fx_pass "N40. a deliberately mixed segment is reported with two owners ('$MIX_O'), so N39's single-owner rows are not vacuous"
    else
        fx_fail "N40. want the mixed segment to report owners 'uv', got '${MIX_O:-empty}'"
    fi
fi

fx_ledger_clear
fx_finish
