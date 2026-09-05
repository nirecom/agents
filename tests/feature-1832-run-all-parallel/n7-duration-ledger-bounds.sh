#!/usr/bin/env bash
# n7-duration-ledger-bounds.sh — the read caps bite, and the sweep spares a live writer.
# Tests: bin/lib/run-all-durations.sh, tests/run-all.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, ledger, TL2, scope:issue-specific

# WHY: n3- only shows that in-range keys resolve, which an unbounded reader would also
# satisfy. These cases plant a key reachable ONLY past each cap, so an absent cap fails
# here; the last one is the retention sweep firing while another runner still owns a file.

# TL3 gap (what this test does NOT catch):
# - more concurrent runners than RUN_ALL_DUR_KEEP_SEGMENTS, an accepted-loss zone by design
# - a months-old ledger whose segments were grown by real runs rather than planted
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category pwsh-required.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "n7-duration-ledger-bounds"

DUR_LIB_REL="bin/lib/run-all-durations.sh"
DUR_LIB="$FX_REPO_ROOT/$DUR_LIB_REL"
PAR_LIB="$FX_REPO_ROOT/bin/lib/run-all-parallelism.sh"

LIB_OK=0
if [ -f "$DUR_LIB" ] && [ -f "$PAR_LIB" ]; then
    # shellcheck source=/dev/null
    . "$PAR_LIB" 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$DUR_LIB" 2>/dev/null || true
    command -v run_all_dur_lookup >/dev/null 2>&1 && LIB_OK=1
fi

lib_missing() {
    [ "$LIB_OK" = "1" ] && return 1
    fx_fail "$1 (implementation missing or unloadable: $DUR_LIB_REL)"
    return 0
}

AG="$FX_TMP_ROOT/agents-under-test"
mkdir -p "$AG"
SCHEMA="${RUN_ALL_DUR_SCHEMA:-1}"
MAX_SEG="${RUN_ALL_DUR_MAX_SEGMENTS_READ:-64}"
MAX_REC="${RUN_ALL_DUR_MAX_RECORDS:-60000}"
KEEP="${RUN_ALL_DUR_KEEP_SEGMENTS:-16}"
HOST_TOK=""
RID=""
if [ "$LIB_OK" = "1" ]; then
    HOST_TOK="$(run_all_dur_host_token 2>/dev/null || true)"
    [ -n "$HOST_TOK" ] || HOST_TOK="${RUN_ALL_DUR_HOST_TOKEN:-}"
    RID="$(run_all_dur_repo_id "$AG" 2>/dev/null || true)"
    [ -n "$RID" ] || RID="${RUN_ALL_DUR_REPO_ID:-}"
fi

KEYS="$FX_TMP_ROOT/keys.tsv"
OUT="$FX_TMP_ROOT/lookup.out"

seg_path() { printf '%s/dur.%s.%s.%s-%s.log\n' "$(fx_ledger_dir)" "$SCHEMA" "$HOST_TOK" "$1" "$2"; }
stamped()  { seg_path "20200101T$(printf '%06d' "$1")" 1; }
fresh_ledger() { fx_ledger_clear; mkdir -p "$(fx_ledger_dir)"; }

secs_for() {
    awk -F'\t' -v want="$1" '$1 == want { print ($2 == "" ? "(empty)" : $2); found = 1; exit }
                             END { if (!found) print "(absent)" }' "$OUT"
}

# ===========================================================================
# N28 — the segment cap is an exact boundary, not an approximation
# ===========================================================================
# Stamps ascend, so the newest segment is #TOTAL. Counting back, position MAX_SEGMENTS_READ
# is the last one read and position MAX_SEGMENTS_READ+1 is the first one skipped. Planting
# one key on each side makes an unbounded reader fail on the OUT key alone.
TOTAL_SEG=$((MAX_SEG + 10))
IN_AT=$((TOTAL_SEG - MAX_SEG + 1))
OUT_AT=$((TOTAL_SEG - MAX_SEG))

if lib_missing "N28. a key one segment past the read cap does not resolve"; then :
elif [ -z "$RID" ]; then
    fx_fail "N28. cannot build the fixture: repo id is empty"
else
    fresh_ledger
    i=1
    while [ "$i" -le "$TOTAL_SEG" ]; do
        printf '%s|1|filler/%s.sh\n' "$RID" "$i" > "$(stamped "$i")"
        i=$((i + 1))
    done
    printf '%s|5|edge/newest.sh\n' "$RID" >> "$(stamped "$TOTAL_SEG")"
    printf '%s|3|edge/in.sh\n' "$RID" >> "$(stamped "$IN_AT")"
    printf '%s|4|edge/out.sh\n' "$RID" >> "$(stamped "$OUT_AT")"
    {
        printf 'k1\tedge/newest.sh\n'
        printf 'k2\tedge/in.sh\n'
        printf 'k3\tedge/out.sh\n'
    } > "$KEYS"

    run_all_dur_lookup "$AG" "$KEYS" "$OUT"
    RC=$?
    G1="$(secs_for k1)"; G2="$(secs_for k2)"; G3="$(secs_for k3)"
    if [ "$RC" -eq 0 ] && [ "$G1" = "5" ] && [ "$G2" = "3" ] && [ "$G3" = "(empty)" ]; then
        fx_pass "N28. of $TOTAL_SEG segments the newest $MAX_SEG were read (newest=5, boundary=3) and segment $((MAX_SEG + 1)) back was not"
    else
        fx_fail "N28. want exit 0 with newest=5, at-cap=3 and past-cap empty over $TOTAL_SEG segments, got exit $RC newest=$G1 at-cap=$G2 past-cap=$G3"
    fi
fi

# ===========================================================================
# N29 — the record cap stops the read before an older segment is ever opened
# ===========================================================================
# The newest segment alone exceeds MAX_RECORDS, so a bounded reader never reaches the
# older file. N19 shows the cap does not FAIL the run; this shows the cap exists at all.
if lib_missing "N29. a key reachable only past the record cap does not resolve"; then :
elif [ -z "$RID" ]; then
    fx_fail "N29. cannot build the fixture: repo id is empty"
else
    fresh_ledger
    printf '%s|4|beyond/cutoff.sh\n' "$RID" > "$(stamped 1)"
    awk -v n=$((MAX_REC + 50)) -v rid="$RID" \
        'BEGIN { for (i = 0; i < n; i++) printf "%s|1|pad/%d.sh\n", rid, i }' > "$(stamped 2)"
    {
        printf 'k1\tbeyond/cutoff.sh\n'
        printf 'k2\tpad/0.sh\n'
    } > "$KEYS"

    run_all_dur_lookup "$AG" "$KEYS" "$OUT"
    RC=$?
    G1="$(secs_for k1)"; G2="$(secs_for k2)"
    if [ "$RC" -eq 0 ] && [ "$G1" = "(empty)" ] && [ "$G2" = "1" ]; then
        fx_pass "N29. the $((MAX_REC + 50))-line newest segment resolved pad/0.sh and the older segment's key stayed unread"
    else
        fx_fail "N29. want exit 0 with the past-cap key empty and pad/0.sh=1, got exit $RC past-cap=$G1 control=$G2"
    fi
    fx_ledger_clear
fi

# ===========================================================================
# N33 — the sweep fires with another runner still holding its segment open
# ===========================================================================
# N10 only ran two runners against an under-cap ledger, where no sweep happens at all.
# Here enough old segments already exist that the second runner's sweep MUST delete
# something; it must delete the oldest, never the live writer's file. Two concurrent
# runners only: the plan accepts data loss beyond KEEP_SEGMENTS writers, so that zone
# is deliberately not entered.
PLANT=$((KEEP + 3))

live_segments() {
    local f
    for f in "$(fx_ledger_dir)"/dur.*; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in *20200101T*) ;; *) basename "$f" ;; esac
    done 2>/dev/null
    return 0
}

X="$(fx_new_root)"
fx_add_dummy "$X" x1 --sleep 1
fx_add_dummy "$X" x2 --sleep 12
Y="$(fx_new_root)"
fx_add_dummy "$Y" y1 --sleep 1

X_OUT="$FX_TMP_ROOT/x.out"; X_ERR="$FX_TMP_ROOT/x.err"
Y_OUT="$FX_TMP_ROOT/y.out"; Y_ERR="$FX_TMP_ROOT/y.err"

FX_LEDGER_KEEP=1
fresh_ledger
i=1
while [ "$i" -le "$PLANT" ]; do
    printf '' > "$(fx_ledger_dir)/dur.$SCHEMA.${HOST_TOK:-0000000000000000}.20200101T0000$(printf '%02d' "$i")-1.log"
    i=$((i + 1))
done

fx_exec_bg "$X" "$X_OUT" "$X_ERR" -j 2 --all
PID_X="$FX_BG_PID"

# Without the library no segment ever appears, so the poll is skipped rather than burning 30s.
A_SEG=""
n=30
[ -f "$DUR_LIB" ] && n=0
while [ "$n" -lt 30 ]; do
    A_SEG="$(live_segments | head -n 1)"
    [ -n "$A_SEG" ] && break
    sleep 1
    n=$((n + 1))
done

fx_exec "$Y" 90 "$Y_OUT" "$Y_ERR" -j 1 --all
Y_EXEC="$(fx_contract_field "$Y_OUT" EXECUTED)"
wait "$PID_X" 2>/dev/null
X_EXEC="$(fx_contract_field "$X_OUT" EXECUTED)"
FX_LEDGER_KEEP=0

A_LINES=0
[ -n "$A_SEG" ] && [ -f "$(fx_ledger_dir)/$A_SEG" ] && \
    A_LINES="$(grep -c '' "$(fx_ledger_dir)/$A_SEG" 2>/dev/null || echo 0)"
AFTER="$(fx_ledger_segments)"

if [ "$X_EXEC" = "2" ] && [ "$Y_EXEC" = "1" ]; then
    fx_pass "N33b. the fixture is real: the long runner executed 2 dummies while the short one executed 1"
else
    fx_fail "N33b. the fixture is not usable — want EXECUTED=2 for the background runner and 1 for the foreground one, got '${X_EXEC:-absent}' and '${Y_EXEC:-absent}'"
    fx_show_tail "$X_ERR" 6
fi

if [ ! -f "$DUR_LIB" ]; then
    fx_fail "N33. a live writer's segment survives a sweep triggered by another runner (implementation missing: $DUR_LIB_REL)"
elif [ -z "$A_SEG" ]; then
    fx_fail "N33. the background runner never created a segment within 30s, so the sweep had no live writer to spare"
elif [ "$A_LINES" = "2" ] && [ "$AFTER" = "$KEEP" ]; then
    fx_pass "N33. with $PLANT old segments planted, the sweep cut back to $KEEP and left the live writer's '$A_SEG' holding both of its records"
else
    fx_fail "N33. want the live segment '$A_SEG' to hold 2 records with exactly $KEEP segments left, got records=$A_LINES segments=$AFTER"
fi
fx_ledger_clear

fx_finish
