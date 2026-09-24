#!/usr/bin/env bash
# n12-duration-ledger-recency.sh — recency is the filename stamp, never the file mtime.
# Tests: bin/lib/run-all-durations.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, ledger, recency, TL2, scope:issue-specific
# WHY: sibling N11 plants its two segments in filename order, so mtime order and stamp order
# agree and a reader sorting by mtime would pass it identically. A copied, restored or synced
# ledger reorders mtimes freely, so the two are made to DISAGREE here: the newer-named segment
# is written first (and back-dated), the older-named one last. The newer NAME must still win.
# TL3 gap: a filesystem with coarse or non-monotonic mtimes on a real host — mitigated at
# WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category pwsh-required.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "n12-duration-ledger-recency"

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
OLD_NAME="20200101T000001"
NEW_NAME="20200101T000002"

seg_path() { printf '%s/dur.%s.%s.%s-1.log\n' "$(fx_ledger_dir)" "$SCHEMA" "$HOST_TOK" "$1"; }

secs_for() {
    awk -F'\t' -v want="$1" '$1 == want { print ($2 == "" ? "(empty)" : $2); found = 1; exit }
                             END { if (!found) print "(absent)" }' "$OUT"
}

# newest_by_mtime — the basename `ls -t` puts first, i.e. the most recently modified segment.
newest_by_mtime() {
    ls -t "$(fx_ledger_dir)"/dur.* 2>/dev/null | head -n 1 | sed 's#.*[/\\]##'
}

printf 'k1\tshared/x.sh\n' > "$KEYS"

# ===========================================================================
# N41 — the newer FILENAME wins even when it is the older file on disk
# ===========================================================================
if lib_missing "N41. the newer filename stamp wins over the newer mtime"; then
    fx_fail "N41a. the fixture's mtime order really disagrees with its filename order (implementation missing or unloadable: $DUR_LIB_REL)"
elif [ -z "$RID" ] || [ -z "$HOST_TOK" ]; then
    fx_fail "N41. cannot build the fixture: repo id='${RID:-empty}' host token='${HOST_TOK:-empty}'"
    fx_fail "N41a. cannot build the fixture: repo id='${RID:-empty}' host token='${HOST_TOK:-empty}'"
else
    fx_ledger_clear
    mkdir -p "$(fx_ledger_dir)"
    # Newer NAME, written FIRST and then back-dated as far as touch allows.
    printf '%s|2|shared/x.sh\n' "$RID" > "$(seg_path "$NEW_NAME")"
    touch -t 202001010000 "$(seg_path "$NEW_NAME")" 2>/dev/null || true
    sleep 1
    # Older NAME, written LAST, so it is unambiguously the newest file on disk.
    printf '%s|9|shared/x.sh\n' "$RID" > "$(seg_path "$OLD_NAME")"
    touch "$(seg_path "$OLD_NAME")" 2>/dev/null || true

    NEWEST_FILE="$(newest_by_mtime)"
    if [ "$NEWEST_FILE" = "dur.$SCHEMA.$HOST_TOK.$OLD_NAME-1.log" ]; then
        fx_pass "N41a. mtime order disagrees with filename order: the OLDER-named '$NEWEST_FILE' is the newest file on disk"
    else
        fx_fail "N41a. the fixture does not create the conflict — want the older-named segment to be newest by mtime, got '${NEWEST_FILE:-none}'"
    fi

    run_all_dur_lookup "$AG" "$KEYS" "$OUT"
    RC=$?
    G1="$(secs_for k1)"
    if [ "$RC" -eq 0 ] && [ "$G1" = "2" ]; then
        fx_pass "N41. the value from the newer-named segment (2) won over the newer-by-mtime file's 9"
    else
        fx_fail "N41. want exit 0 and 2, the newer-named segment's value, got exit $RC value='$G1' (9 means mtime decided recency)"
    fi
fi

# ===========================================================================
# N42 — the same conflict with the values swapped
# ===========================================================================
# N41 alone would also pass for a reader that always returns the smaller number.
if lib_missing "N42. the newer filename still wins when it holds the larger value"; then :
elif [ -z "$RID" ] || [ -z "$HOST_TOK" ]; then
    fx_fail "N42. cannot build the fixture: repo id='${RID:-empty}' host token='${HOST_TOK:-empty}'"
else
    fx_ledger_clear
    mkdir -p "$(fx_ledger_dir)"
    printf '%s|9|shared/x.sh\n' "$RID" > "$(seg_path "$NEW_NAME")"
    touch -t 202001010000 "$(seg_path "$NEW_NAME")" 2>/dev/null || true
    sleep 1
    printf '%s|2|shared/x.sh\n' "$RID" > "$(seg_path "$OLD_NAME")"
    touch "$(seg_path "$OLD_NAME")" 2>/dev/null || true

    run_all_dur_lookup "$AG" "$KEYS" "$OUT"
    RC=$?
    G2="$(secs_for k1)"
    if [ "$RC" -eq 0 ] && [ "$G2" = "9" ]; then
        fx_pass "N42. with the values swapped the newer-named segment still won (9, not the newest file's 2)"
    else
        fx_fail "N42. want exit 0 and 9 from the newer-named segment, got exit $RC value='$G2'"
    fi
    fx_ledger_clear
fi

fx_finish
