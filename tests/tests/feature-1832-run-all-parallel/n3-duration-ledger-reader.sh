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
        printf '%s|12345|PASS|completed|five/digits.sh\n' "$RID"
        printf '%s|7|PASS|completed|\n' "$RID"
        printf '%s|3|PASS|completed|good/a.sh\n' "$RID"
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
    printf '%s|%s|PASS|completed|shared/x.sh\n' "$RID" "$1" > "$(seg_path 20200101T000001 1)"
    printf '%s|%s|PASS|completed|shared/x.sh\n' "$RID" "$2" > "$(seg_path 20200101T000002 1)"
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
        printf '%s|9|PASS|completed|shared/x.sh\n' "$RID"
        printf '%s|2|PASS|completed|shared/x.sh\n' "$RID"
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
# N14 — the tier is floor(log2(secs)), pinned directly by a table
# ===========================================================================
# #2079 removes run_all_count_bucket, so the tier is pinned by literal expected values
# instead of by agreement with it (the formula itself must not drift either).
if lib_missing "N14. run_all_dur_tier classifies the 12-value table"; then :
else
    DRIFT=""
    for PAIR in 0:0 1:0 2:1 3:1 4:2 7:2 8:3 15:3 16:4 31:4 1000:9 9999:13; do
        SECS="${PAIR%%:*}"; WANT="${PAIR#*:}"
        T="$(run_all_dur_tier "$SECS" 2>/dev/null || true)"
        [ "$T" = "$WANT" ] || DRIFT="$DRIFT $SECS(want=$WANT got=${T:-absent})"
    done
    if [ -z "$DRIFT" ]; then
        fx_pass "N14. all 12 table values classify to floor(log2(secs)) under run_all_dur_tier"
    else
        fx_fail "N14. run_all_dur_tier drifted from the pinned table at:$DRIFT"
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
    printf '%s|4|PASS|completed|%s\n' "$RID" "$EVIL" > "$(seg_path 20200101T000001 1)"
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
# The lookup alone never consolidates, and young open segments are never consolidated
# anyway (#2079 S7b), so this many files on disk is a state the reader must bound itself.
PLANT=216
if lib_missing "N18a. planted values resolve with $PLANT segments on disk"; then
    fx_fail "N18b. RUN_ALL_DUR_SEGMENTS_READ is exactly $MAX_SEG (implementation missing or unloadable: $DUR_LIB_REL)"
else
    fresh_ledger
    i=1
    while [ "$i" -le "$PLANT" ]; do
        printf '%s|1|PASS|completed|filler/%s.sh\n' "$RID" "$i" > "$(seg_path "20200101T$(printf '%06d' "$i")" 1)"
        i=$((i + 1))
    done
    printf '%s|6|PASS|completed|planted/newest.sh\n' "$RID" >> "$(seg_path "20200101T$(printf '%06d' "$PLANT")" 1)"
    printf '%s|4|PASS|completed|planted/inside.sh\n' "$RID" >> "$(seg_path "20200101T$(printf '%06d' $((PLANT - 10)))" 1)"
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
    printf '%s|5|PASS|completed|early/known.sh\n' "$RID" > "$PAD_SEG"
    awk -v n=$((MAX_REC + 100)) -v rid="$RID" \
        'BEGIN { for (i = 0; i < n; i++) printf "%s|1|PASS|completed|pad/%d.sh\n", rid, i }' >> "$PAD_SEG"
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

# ===========================================================================
# N22 — the optional 4th argument returns the termination of the line the seconds came from (#3047)
# ===========================================================================
# term_for <id> — the termination the reader wrote for that id, "(empty)" / "(absent)" as secs_for.
term_for() {
    awk -F'\t' -v want="$1" '$1 == want { print ($2 == "" ? "(empty)" : $2); found = 1; exit }
                             END { if (!found) print "(absent)" }' "$TERM_OUT"
}
TERM_OUT="$FX_TMP_ROOT/lookup.term"

if lib_missing "N22a. three arguments: the out file is byte-identical with and without a term file"; then
    fx_fail "N22b. the term file names each key's newest termination (implementation missing or unloadable: $DUR_LIB_REL)"
else
    fresh_ledger
    {
        printf '%s|748|FAIL|completed|done/c.sh\n' "$RID"
        printf '%s|400|-|timeout|done/c.sh\n' "$RID"
        printf '%s|400|-|timeout|late/c.sh\n' "$RID"
        printf '%s|927|FAIL|completed|late/c.sh\n' "$RID"
        printf '%s|5|?|?|legacy/q.sh\n' "$RID"
    } > "$(seg_path 20200101T000001 1)"
    printf '%s|9|PASS|completed|cross/s.sh\n' "$RID" >> "$(seg_path 20200101T000001 1)"
    printf '%s|30|-|timeout|cross/s.sh\n' "$RID" > "$(seg_path 20200101T000002 1)"
    {
        printf 'k1\tdone/c.sh\n'
        printf 'k2\tlate/c.sh\n'
        printf 'k3\tlegacy/q.sh\n'
        printf 'k4\tcross/s.sh\n'
        printf 'k5\tnever/recorded.sh\n'
    } > "$KEYS"
    run_all_dur_lookup "$AG" "$KEYS" "$OUT"
    RC3=$?
    cp "$OUT" "$FX_TMP_ROOT/lookup3.out"
    WANT3="$(printf 'k1\t400\nk2\t927\nk3\t5\nk4\t30\nk5\t')"
    GOT3="$(cat "$OUT")"
    rm -f "$TERM_OUT"
    run_all_dur_lookup "$AG" "$KEYS" "$OUT" "$TERM_OUT"
    RC4=$?
    if [ "$RC3" -eq 0 ] && [ "$GOT3" = "$WANT3" ] && [ "$RC4" -eq 0 ] && cmp -s "$OUT" "$FX_TMP_ROOT/lookup3.out"; then
        fx_pass "N22a. the 3-argument out file is unchanged (pinned) and identical when a term file is also asked for"
    else
        fx_fail "N22a. want exit 0 twice and the pinned out [$WANT3] both times, got exit $RC3/$RC4 out3=[$GOT3] out4=[$(cat "$OUT" 2>/dev/null)]"
    fi
    if [ -f "$TERM_OUT" ]; then
        T1="$(term_for k1)"; T2="$(term_for k2)"; T3="$(term_for k3)"; T4="$(term_for k4)"; T5="$(term_for k5)"
        ROWS="$(grep -c '' "$TERM_OUT" 2>/dev/null || true)"
        ORDER="$(cut -f1 "$TERM_OUT" | tr '\n' ' ')"
    else
        T1="(no file)" T2="" T3="" T4="" T5="" ROWS=0 ORDER=""
    fi
    if [ "$T1" = "timeout" ] && [ "$T2" = "completed" ] && [ "$T3" = "?" ] && [ "$T4" = "timeout" ] \
        && [ "$T5" = "(empty)" ] && [ "$ROWS" = "5" ] && [ "$ORDER" = "k1 k2 k3 k4 k5 " ]; then
        fx_pass "N22b. the term file names the newest line's termination per key, in keys order (later line, newer segment)"
    else
        fx_fail "N22b. want timeout/completed/?/timeout/(empty) in order k1..k5, got $T1/$T2/$T3/$T4/$T5 rows=$ROWS order=[$ORDER]"
    fi
fi

if lib_missing "N22c. no ledger at all: the term file still has one blank row per key"; then :
else
    fresh_ledger
    printf 'k1\tdone/c.sh\nk2\tlate/c.sh\n' > "$KEYS"
    rm -f "$TERM_OUT"
    run_all_dur_lookup "$AG" "$KEYS" "$OUT" "$TERM_OUT"
    RC=$?
    GOT="$(cat "$TERM_OUT" 2>/dev/null || printf '(no file)')"
    if [ "$RC" -eq 0 ] && [ "$GOT" = "$(printf 'k1\t\nk2\t')" ]; then
        fx_pass "N22c. with no segment the term file holds k1 and k2 with empty terminations"
    else
        fx_fail "N22c. want exit 0 and two blank rows, got exit $RC term=[$GOT]"
    fi
    fx_ledger_clear
fi

fx_finish
