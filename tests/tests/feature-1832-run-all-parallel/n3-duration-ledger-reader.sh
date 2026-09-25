#!/usr/bin/env bash
# n3-duration-ledger-reader.sh — the reader: line-wise skip, recency, tier table, read bounds.
# Tests: bin/lib/run-all-durations.sh, bin/lib/run-all-parallelism.sh, tests/run-all.sh
# Tags: tests, bin, parallel, ledger, TL2, scope:issue-specific

# WHY: these cases call the library directly, because the properties under test (which record
# wins, how much is read at all) are invisible from the runner's plan surface. Writer cases
# live in n-, plan-surface cases in n2-, worktree sharing in n4-.

# TL3 gap (what this test does NOT catch):
# - a real ledger grown by months of runs rather than planted segments
# - a host whose awk is not the one on this machine (POSIX subset is assumed, not proven)
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category pwsh-required.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "n3-duration-ledger-reader"

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

# Every row names the absent implementation instead of crashing (RED-FIRST).
lib_missing() {
    [ "$LIB_OK" = "1" ] && return 1
    fx_fail "$1 (implementation missing or unloadable: $DUR_LIB_REL)"
    return 0
}

AG="$FX_TMP_ROOT/agents-under-test"
mkdir -p "$AG"
SCHEMA="${RUN_ALL_DUR_SCHEMA:-1}"
UNMEASURED="${RUN_ALL_DUR_TIER_UNMEASURED:-99}"
MAX_SEG="${RUN_ALL_DUR_MAX_SEGMENTS_READ:-64}"
MAX_REC="${RUN_ALL_DUR_MAX_RECORDS:-60000}"
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

# secs_for <id> — the value the reader resolved for that keys-file id, "(absent)" if the row is gone.
secs_for() {
    awk -F'\t' -v want="$1" '$1 == want { print ($2 == "" ? "(empty)" : $2); found = 1; exit }
                             END { if (!found) print "(absent)" }' "$OUT"
}

fresh_ledger() {
    fx_ledger_clear
    mkdir -p "$(fx_ledger_dir)"
}

# ===========================================================================
# N8 — a broken line costs its own line, never the file
# ===========================================================================
if lib_missing "N8. malformed records are skipped line-wise"; then :
else
    fresh_ledger
    {
        printf 'not a record at all\n'
        printf '%s|5|a|b\n' "$RID"
        printf '%s|12345|five/digits.sh\n' "$RID"
        printf '%s|7|\n' "$RID"
        printf '%s|3|good/a.sh\n' "$RID"
    } > "$(seg_path 20200101T000001 1)"
    {
        printf 'k1\tgood/a.sh\n'
        printf 'k2\tfive/digits.sh\n'
        printf 'k3\tnever/recorded.sh\n'
        printf 'k4\t\n'
    } > "$KEYS"

    run_all_dur_lookup "$AG" "$KEYS" "$OUT"
    RC=$?
    ROWS="$(grep -c '' "$OUT" 2>/dev/null || true)"
    G1="$(secs_for k1)"; G2="$(secs_for k2)"; G3="$(secs_for k3)"; G4="$(secs_for k4)"
    if [ "$RC" -eq 0 ] && [ "$ROWS" = "4" ] && [ "$G1" = "3" ] && \
       [ "$G2" = "(empty)" ] && [ "$G3" = "(empty)" ] && [ "$G4" = "(empty)" ]; then
        fx_pass "N8. the one valid record after four broken lines still resolved, and nothing else did"
    else
        fx_fail "N8. want exit 0, 4 rows, k1=3 and k2/k3/k4 empty, got exit $RC rows=$ROWS k1=$G1 k2=$G2 k3=$G3 k4=$G4"
    fi
fi

# ===========================================================================
# N11 — across segments, the newer stamp wins (both directions)
# ===========================================================================
printf 'k1\tshared/x.sh\n' > "$KEYS"

# n11_case <old-secs> <new-secs> — resolves shared/x.sh with those two segments planted.
n11_case() {
    fresh_ledger
    printf '%s|%s|shared/x.sh\n' "$RID" "$1" > "$(seg_path 20200101T000001 1)"
    printf '%s|%s|shared/x.sh\n' "$RID" "$2" > "$(seg_path 20200101T000002 1)"
    run_all_dur_lookup "$AG" "$KEYS" "$OUT" || return 1
    secs_for k1
}

if lib_missing "N11. the newer segment wins regardless of value"; then :
else
    A="$(n11_case 9 2)"
    B="$(n11_case 2 9)"
    if [ "$A" = "2" ] && [ "$B" = "9" ]; then
        fx_pass "N11. the newer segment won in both directions (9-then-2 gave 2, 2-then-9 gave 9)"
    else
        fx_fail "N11. want 2 from the older=9/newer=2 pair and 9 from the swapped pair, got '$A' and '$B'"
    fi
fi

# ===========================================================================
# N12 — within one segment, the later line wins
# ===========================================================================
if lib_missing "N12. the later line in a segment wins"; then :
else
    fresh_ledger
    {
        printf '%s|9|shared/x.sh\n' "$RID"
        printf '%s|2|shared/x.sh\n' "$RID"
    } > "$(seg_path 20200101T000001 1)"
    run_all_dur_lookup "$AG" "$KEYS" "$OUT"
    RC=$?
    G1="$(secs_for k1)"
    if [ "$RC" -eq 0 ] && [ "$G1" = "2" ]; then
        fx_pass "N12. two records for one key in one segment resolved to the later line (2, not 9)"
    else
        fx_fail "N12. want exit 0 and 2 (the later line), got exit $RC value='$G1'"
    fi
fi

# ===========================================================================
# N14 — the tier duplicate must not drift from run_all_count_bucket
# ===========================================================================
# run_all_dur_tier_into deliberately re-implements run_all_count_bucket to avoid one fork
# per test. This table is the mechanical proof that the duplicate still classifies alike.
if lib_missing "N14. run_all_dur_tier agrees with run_all_count_bucket"; then :
elif ! command -v run_all_count_bucket >/dev/null 2>&1; then
    fx_fail "N14. run_all_count_bucket is not available from $PAR_LIB"
else
    DRIFT=""
    for SECS in 0 1 2 3 4 7 8 15 16 31 1000 9999; do
        T="$(run_all_dur_tier "$SECS" 2>/dev/null || true)"
        B="$(run_all_count_bucket "$SECS" 2>/dev/null || true)"
        [ "$T" = "$B" ] || DRIFT="$DRIFT $SECS(tier=${T:-absent} bucket=${B:-absent})"
    done
    if [ -z "$DRIFT" ]; then
        fx_pass "N14. all 12 table values classify identically under run_all_dur_tier and run_all_count_bucket"
    else
        fx_fail "N14. the intentional duplicate has drifted at:$DRIFT"
    fi
fi

if lib_missing "N14b. non-numeric and empty input map to the unmeasured tier"; then :
else
    T1="$(run_all_dur_tier "" 2>/dev/null || true)"
    T2="$(run_all_dur_tier "abc" 2>/dev/null || true)"
    T3="$(run_all_dur_tier "-3" 2>/dev/null || true)"
    if [ "$T1" = "$UNMEASURED" ] && [ "$T2" = "$UNMEASURED" ] && [ "$T3" = "$UNMEASURED" ]; then
        fx_pass "N14b. empty, alphabetic and negative input all map to tier $UNMEASURED"
    else
        fx_fail "N14b. want $UNMEASURED for '', 'abc' and '-3', got '$T1' '$T2' '$T3'"
    fi
fi

# ===========================================================================
# N21 — a hostile key is data, never code
# ===========================================================================
# The ledger is written by whatever ran last in this repo, so its keys are untrusted input
# to every later run. They must round-trip verbatim without ever reaching a shell.
if lib_missing "N21. shell metacharacters in a key are neither executed nor leaked"; then :
else
    fresh_ledger
    MARK="$FX_TMP_ROOT/pwned-marker"
    rm -f "$MARK" 2>/dev/null || true
    EVIL='$(touch '"$MARK"')`touch '"$MARK"'`; rm -rf /tmp/nope; evil.sh'
    printf '%s|4|%s\n' "$RID" "$EVIL" > "$(seg_path 20200101T000001 1)"
    printf 'k1\t%s\n' "$EVIL" > "$KEYS"

    run_all_dur_lookup "$AG" "$KEYS" "$OUT"
    RC=$?
    G1="$(secs_for k1)"
    LEAK=0
    grep -qF 'touch' "$OUT" && LEAK=1
    if [ "$RC" -eq 0 ] && [ ! -e "$MARK" ] && [ "$G1" = "4" ] && [ "$LEAK" = "0" ]; then
        fx_pass "N21. the metacharacter key resolved to 4 with nothing executed and nothing echoed back"
    else
        fx_fail "N21. want exit 0, no $MARK, value 4 and no key text in the out file, got exit $RC marker-exists=$([ -e "$MARK" ] && echo yes || echo no) value=$G1 leak=$LEAK"
    fi
    rm -f "$MARK" 2>/dev/null || true
fi

# ===========================================================================
# N18 — read volume is capped independently of how many segments are on disk
# ===========================================================================
# The sweep is bypassed entirely: these files are planted, so this is what a permanently
# failing sweep looks like to the reader.
PLANT=$((${RUN_ALL_DUR_KEEP_SEGMENTS:-16} + 200))
if lib_missing "N18a. planted values resolve with $PLANT segments on disk"; then
    fx_fail "N18b. RUN_ALL_DUR_SEGMENTS_READ is exactly $MAX_SEG (implementation missing or unloadable: $DUR_LIB_REL)"
else
    fresh_ledger
    i=1
    while [ "$i" -le "$PLANT" ]; do
        printf '%s|1|filler/%s.sh\n' "$RID" "$i" > "$(seg_path "20200101T$(printf '%06d' "$i")" 1)"
        i=$((i + 1))
    done
    printf '%s|6|planted/newest.sh\n' "$RID" >> "$(seg_path "20200101T$(printf '%06d' "$PLANT")" 1)"
    printf '%s|4|planted/inside.sh\n' "$RID" >> "$(seg_path "20200101T$(printf '%06d' $((PLANT - 10)))" 1)"
    {
        printf 'k1\tplanted/newest.sh\n'
        printf 'k2\tplanted/inside.sh\n'
        printf 'k3\tfiller/1.sh\n'
    } > "$KEYS"

    RUN_ALL_DUR_SEGMENTS_READ=""
    run_all_dur_lookup "$AG" "$KEYS" "$OUT"
    RC=$?
    READ_N="${RUN_ALL_DUR_SEGMENTS_READ:-}"
    G1="$(secs_for k1)"; G2="$(secs_for k2)"
    ONDISK="$(fx_ledger_segments)"
    if [ "$RC" -eq 0 ] && [ "$G1" = "6" ] && [ "$G2" = "4" ] && [ "$ONDISK" = "$PLANT" ]; then
        fx_pass "N18a. with $PLANT segments on disk the two newest planted values resolved (6 and 4)"
    else
        fx_fail "N18a. want exit 0 with k1=6 k2=4 over $PLANT planted segments, got exit $RC k1=$G1 k2=$G2 on-disk=$ONDISK"
    fi
    if [ "$READ_N" = "$MAX_SEG" ]; then
        fx_pass "N18b. RUN_ALL_DUR_SEGMENTS_READ is exactly $MAX_SEG, not the $PLANT present on disk"
    else
        fx_fail "N18b. want RUN_ALL_DUR_SEGMENTS_READ=$MAX_SEG independent of the $PLANT segments on disk, got '${READ_N:-unset}'"
    fi
fi

# ===========================================================================
# N19 — the total-lines cutoff still produces a complete out file
# ===========================================================================
if lib_missing "N19. a segment longer than $MAX_REC lines is truncated, not failed"; then :
else
    fresh_ledger
    PAD_SEG="$(seg_path 20200101T000001 1)"
    printf '%s|5|early/known.sh\n' "$RID" > "$PAD_SEG"
    awk -v n=$((MAX_REC + 100)) -v rid="$RID" \
        'BEGIN { for (i = 0; i < n; i++) printf "%s|1|pad/%d.sh\n", rid, i }' >> "$PAD_SEG"
    {
        printf 'k1\tearly/known.sh\n'
        printf 'k2\tpad/0.sh\n'
    } > "$KEYS"

    run_all_dur_lookup "$AG" "$KEYS" "$OUT"
    RC=$?
    ROWS="$(grep -c '' "$OUT" 2>/dev/null || true)"
    G1="$(secs_for k1)"
    if [ "$RC" -eq 0 ] && [ "$ROWS" = "2" ] && [ "$G1" = "5" ]; then
        fx_pass "N19. a $((MAX_REC + 101))-line segment still exits 0 and resolves the value read before the cutoff"
    else
        fx_fail "N19. want exit 0, 2 rows and k1=5 from before the cutoff, got exit $RC rows=$ROWS k1=$G1"
    fi
    fx_ledger_clear
fi

fx_finish
