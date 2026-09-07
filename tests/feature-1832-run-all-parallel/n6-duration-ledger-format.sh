#!/usr/bin/env bash
# n6-duration-ledger-format.sh — the ledger line and segment-name grammars, table-driven.
# Tests: bin/lib/run-all-durations.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, ledger, parser, TL2, scope:issue-specific

# WHY: the reader is a line-format parser over a file any earlier run may have written, so
# skills/_shared/test-design/parser-regex-tests.md requires an explicit accepted-vs-rejected
# table. One row per class means a relaxed field rule shows up as that row, not as a whole run.

# TL3 gap (what this test does NOT catch):
# - a TAB in a key, and a CR immediately before the newline: neither is representable here
#   (the keys file is TAB-separated, and awk's line splitting is CRLF-aware on some hosts)
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category pwsh-required.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "n6-duration-ledger-format"

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
CR=$'\r'

seg_path() { printf '%s/dur.%s.%s.%s-%s.log\n' "$(fx_ledger_dir)" "$SCHEMA" "$HOST_TOK" "$1" "$2"; }
fresh_ledger() { fx_ledger_clear; mkdir -p "$(fx_ledger_dir)"; }

secs_for() {
    awk -F'\t' -v want="$1" '$1 == want { print ($2 == "" ? "(empty)" : $2); found = 1; exit }
                             END { if (!found) print "(absent)" }' "$OUT"
}

# The raw record must travel inside a pipe-delimited table, so the field separator,
# the repo id and a carriage return are carried as placeholders and restored here.
expand_raw() {
    local s="$1"
    s="${s//@RID@/$RID}"
    s="${s//@P@/|}"
    s="${s//%CR%/$CR}"
    printf '%s' "$s"
}

# ===========================================================================
# N26 — the record grammar: <repo_id 16 alnum>|<secs 1-4 digits>|<non-empty key>
# ===========================================================================
# Spaces and non-ASCII are DATA, not delimiters: only |, TAB, CR, LF and emptiness
# disqualify a key. Every row below is planted in one segment and resolved in one call,
# so a rule that leaks (say, dropping the NF check) surfaces as exactly its own row.
LINE_TABLE='
ok_zero|@RID@@P@0@P@t/ok-zero.sh|t/ok-zero.sh|0
ok_mid|@RID@@P@7@P@t/ok-mid.sh|t/ok-mid.sh|7
ok_max_digits|@RID@@P@9999@P@t/ok-max.sh|t/ok-max.sh|9999
ok_dotted|@RID@@P@3@P@t/sub.dir/ok.dots.sh|t/sub.dir/ok.dots.sh|3
ok_inner_space|@RID@@P@5@P@t/with space.sh|t/with space.sh|5
ok_leading_space|@RID@@P@8@P@ t/lead-space.sh| t/lead-space.sh|8
ok_non_ascii|@RID@@P@6@P@t/naïve-café-tëst.sh|t/naïve-café-tëst.sh|6
bad_secs_5digits|@RID@@P@12345@P@t/bad-5digits.sh|t/bad-5digits.sh|(empty)
bad_secs_empty|@RID@@P@@P@t/bad-secs-empty.sh|t/bad-secs-empty.sh|(empty)
bad_secs_alpha|@RID@@P@abc@P@t/bad-secs-alpha.sh|t/bad-secs-alpha.sh|(empty)
bad_secs_negative|@RID@@P@-3@P@t/bad-secs-neg.sh|t/bad-secs-neg.sh|(empty)
bad_secs_plus|@RID@@P@+3@P@t/bad-secs-plus.sh|t/bad-secs-plus.sh|(empty)
bad_secs_float|@RID@@P@1.5@P@t/bad-secs-float.sh|t/bad-secs-float.sh|(empty)
bad_secs_padded|@RID@@P@ 3@P@t/bad-secs-pad.sh|t/bad-secs-pad.sh|(empty)
bad_two_fields|@RID@@P@t/bad-two.sh|t/bad-two.sh|(empty)
bad_four_fields|@RID@@P@4@P@t/bad-four.sh@P@extra|t/bad-four.sh|(empty)
bad_no_separator|@RID@ 4 t/bad-nopipe.sh|t/bad-nopipe.sh|(empty)
bad_repo_id_other|ZZZZZZZZZZZZZZZZ@P@4@P@t/bad-rid-other.sh|t/bad-rid-other.sh|(empty)
bad_repo_id_short|ZZZZZZZZZZZZZZZ@P@4@P@t/bad-rid-short.sh|t/bad-rid-short.sh|(empty)
bad_repo_id_long|ZZZZZZZZZZZZZZZZZ@P@4@P@t/bad-rid-long.sh|t/bad-rid-long.sh|(empty)
bad_key_inner_cr|@RID@@P@4@P@t/bad%CR%cr.sh|t/bad-cr.sh|(empty)
bad_key_empty|@RID@@P@4@P@||(empty)
'

if lib_missing "N26a. every accepted record class resolves to its own value"; then
    fx_fail "N26b. every rejected record class resolves to nothing (implementation missing or unloadable: $DUR_LIB_REL)"
elif [ -z "$RID" ] || [ "$RID" = "ZZZZZZZZZZZZZZZZ" ]; then
    fx_fail "N26a. cannot build the table: repo id is '${RID:-empty}' (must be a real 16-char id, not the decoy)"
    fx_fail "N26b. cannot build the table: repo id is '${RID:-empty}'"
else
    fresh_ledger
    SEG="$(seg_path 20200101T000001 1)"
    : > "$SEG"
    : > "$KEYS"
    while IFS='|' read -r name raw key want; do
        [ -n "$name" ] || continue
        expand_raw "$raw" >> "$SEG"
        printf '\n' >> "$SEG"
        printf '%s\t%s\n' "$name" "$key" >> "$KEYS"
    done <<TABLE
$LINE_TABLE
TABLE

    run_all_dur_lookup "$AG" "$KEYS" "$OUT"
    N26_RC=$?
    OK_BAD=""; REJ_BAD=""
    while IFS='|' read -r name raw key want; do
        [ -n "$name" ] || continue
        got="$(secs_for "$name")"
        [ "$got" = "$want" ] && continue
        case "$name" in
            ok_*)  OK_BAD="$OK_BAD $name(want=$want got=$got)" ;;
            *)     REJ_BAD="$REJ_BAD $name(want=$want got=$got)" ;;
        esac
    done <<TABLE
$LINE_TABLE
TABLE

    if [ "$N26_RC" -eq 0 ] && [ -z "$OK_BAD" ]; then
        fx_pass "N26a. every accepted class (0/4-digit seconds, dots, inner and leading spaces, non-ASCII) resolved to its own value"
    else
        fx_fail "N26a. exit $N26_RC; accepted classes that did not resolve correctly:${OK_BAD:- none}"
    fi
    if [ "$N26_RC" -eq 0 ] && [ -z "$REJ_BAD" ]; then
        fx_pass "N26b. every rejected class (5-digit/non-numeric/padded seconds, wrong field count, foreign or mis-sized repo id, CR, empty key) resolved to nothing"
    else
        fx_fail "N26b. exit $N26_RC; rejected classes that leaked a value:${REJ_BAD:- none}"
    fi
fi

# ===========================================================================
# N27 — the segment-name grammar decides which files are read at all
# ===========================================================================
# Same record in every case; only the file NAME changes. A reader that globs too widely
# would read another host's or another schema's segment as if it were ours — the isolation
# the schema and host fields exist for. Only the three fields the format PINS are varied:
# how much of the stamp-and-pid tail the glob spells out is an implementation choice.
NAME_TABLE='
current|dur.%S%.%H%.20200101T000009-1.log|8
other_host|dur.%S%.ABCDEFGHIJKLMNOP.20200101T000009-1.log|(empty)
other_schema|dur.9.%H%.20200101T000009-1.log|(empty)
other_prefix|durations.%S%.%H%.20200101T000009-1.log|(empty)
'

if lib_missing "N27. only segments in this host's own naming class are read"; then :
elif [ -z "$HOST_TOK" ] || [ -z "$RID" ]; then
    fx_fail "N27. cannot build the table: host token='${HOST_TOK:-empty}' repo id='${RID:-empty}'"
else
    printf 'k1\tseg/probe.sh\n' > "$KEYS"
    NAME_BAD=""
    while IFS='|' read -r name fname want; do
        [ -n "$name" ] || continue
        fname="${fname//%S%/$SCHEMA}"
        fname="${fname//%H%/$HOST_TOK}"
        fresh_ledger
        printf '%s|8|seg/probe.sh\n' "$RID" > "$(fx_ledger_dir)/$fname"
        run_all_dur_lookup "$AG" "$KEYS" "$OUT" || true
        got="$(secs_for k1)"
        [ "$got" = "$want" ] || NAME_BAD="$NAME_BAD $name(want=$want got=$got)"
    done <<TABLE
$NAME_TABLE
TABLE

    if [ -z "$NAME_BAD" ]; then
        fx_pass "N27. the current-host segment was read and the foreign host, schema and prefix classes were all invisible"
    else
        fx_fail "N27. segment-name classes handled wrongly:$NAME_BAD"
    fi
fi

# ===========================================================================
# N35 — a same-stamp tie between two writers resolves deterministically
# ===========================================================================
# Which of the two values wins is deliberately unspecified (the plan records the tie as an
# accepted ambiguity); what must NOT happen is a different winner on consecutive reads,
# because that would make the plan order irreproducible for the same on-disk ledger.
if lib_missing "N35. two same-stamp segments with conflicting values resolve the same way every time"; then :
else
    fresh_ledger
    printf '%s|2|tie/x.sh\n' "$RID" > "$(seg_path 20200101T000005 1)"
    printf '%s|9|tie/x.sh\n' "$RID" > "$(seg_path 20200101T000005 2)"
    printf 'k1\ttie/x.sh\n' > "$KEYS"

    run_all_dur_lookup "$AG" "$KEYS" "$OUT" || true; T1="$(secs_for k1)"
    run_all_dur_lookup "$AG" "$KEYS" "$OUT" || true; T2="$(secs_for k1)"
    run_all_dur_lookup "$AG" "$KEYS" "$OUT" || true; T3="$(secs_for k1)"
    if [ "$T1" = "$T2" ] && [ "$T2" = "$T3" ] && { [ "$T1" = "2" ] || [ "$T1" = "9" ]; }; then
        fx_pass "N35. three consecutive reads of the tied pair all returned $T1, one of the two planted values"
    else
        fx_fail "N35. want one stable value from {2,9} across three reads, got '$T1' '$T2' '$T3'"
    fi
    fx_ledger_clear
fi

fx_finish
