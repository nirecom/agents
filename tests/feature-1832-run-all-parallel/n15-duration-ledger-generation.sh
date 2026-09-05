#!/usr/bin/env bash
# n15-duration-ledger-generation.sh — retention spends old segments before current ones.
# Tests: bin/lib/run-all-durations.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, ledger, retention, TL2, scope:issue-specific
# WHY: sibling N7 plants ONLY 2020-stamped segments, so it cannot tell retention-by-age from
# retention-by-anything-else — every survivor it checks is arbitrary. Here both generations are
# on disk at once: when the current generation fits under KEEP every current segment must
# survive and only old ones may go, and when it does not, the survivors must still be the
# newest current ones — the documented accepted-loss boundary, asserted rather than assumed.
# TL3 gap: a real months-old ledger swept during live concurrent writes — mitigated at
# WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category pwsh-required.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "n15-duration-ledger-generation"

DUR_LIB_REL="bin/lib/run-all-durations.sh"
DUR_LIB="$FX_REPO_ROOT/$DUR_LIB_REL"
PAR_LIB="$FX_REPO_ROOT/bin/lib/run-all-parallelism.sh"

LIB_OK=0
if [ -f "$DUR_LIB" ] && [ -f "$PAR_LIB" ]; then
    # shellcheck source=/dev/null
    . "$PAR_LIB" 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$DUR_LIB" 2>/dev/null || true
    command -v run_all_dur_sweep >/dev/null 2>&1 && LIB_OK=1
fi

lib_missing() {
    [ "$LIB_OK" = "1" ] && return 1
    fx_fail "$1 (implementation missing or unloadable: $DUR_LIB_REL)"
    return 0
}

SCHEMA="${RUN_ALL_DUR_SCHEMA:-1}"
KEEP="${RUN_ALL_DUR_KEEP_SEGMENTS:-16}"
HOST_TOK=""
[ "$LIB_OK" = "1" ] && HOST_TOK="$(run_all_dur_host_token 2>/dev/null || true)"
[ -n "$HOST_TOK" ] || HOST_TOK="${RUN_ALL_DUR_HOST_TOKEN:-}"

# The current generation is stamped with today's UTC date, the old one with 2020: the C-collated
# glob the sweep walks therefore puts every old segment strictly before every current one.
CUR_DAY="$(date -u +%Y%m%d 2>/dev/null || printf '20990101')"

old_seg() { printf '%s/dur.%s.%s.20200101T0000%02d-1.log\n' "$(fx_ledger_dir)" "$SCHEMA" "$HOST_TOK" "$1"; }
cur_seg() { printf '%s/dur.%s.%s.%sT1000%02d-1.log\n' "$(fx_ledger_dir)" "$SCHEMA" "$HOST_TOK" "$CUR_DAY" "$1"; }

# plant <old-count> <current-count> — a fresh ledger holding both generations.
plant() {
    local i
    fx_ledger_clear
    mkdir -p "$(fx_ledger_dir)"
    for ((i = 1; i <= $1; i++)); do printf 'old %s\n' "$i" > "$(old_seg "$i")"; done
    for ((i = 1; i <= $2; i++)); do printf 'cur %s\n' "$i" > "$(cur_seg "$i")"; done
    return 0
}

# survivors <old-count> <current-count> — "<old-alive> <cur-alive> <first-cur-alive> <last-old-alive>"
survivors() {
    local i o=0 c=0 firstc=0 lasto=0
    for ((i = 1; i <= $1; i++)); do [ -e "$(old_seg "$i")" ] && { o=$((o + 1)); lasto="$i"; }; done
    for ((i = 1; i <= $2; i++)); do
        if [ -e "$(cur_seg "$i")" ]; then c=$((c + 1)); [ "$firstc" -eq 0 ] && firstc="$i"; fi
    done
    printf '%s %s %s %s\n' "$o" "$c" "$firstc" "$lasto"
}

# ===========================================================================
# N47 — a current generation that fits under KEEP is never touched
# ===========================================================================
A_OLD=10
A_CUR=$((KEEP - 2))
A_TOTAL=$((A_OLD + A_CUR))
A_OLD_LEFT=$((KEEP - A_CUR))

if lib_missing "N47. with $A_CUR current segments under a KEEP of $KEEP, only old segments are swept"; then :
elif [ -z "$HOST_TOK" ]; then
    fx_fail "N47. cannot build the fixture: the host token is empty"
else
    plant "$A_OLD" "$A_CUR"
    A_PLANTED="$(fx_ledger_segments)"
    run_all_dur_sweep
    A_AFTER="$(fx_ledger_segments)"
    read -r A_O A_C A_FIRSTC A_LASTO <<<"$(survivors "$A_OLD" "$A_CUR")"

    if [ "$A_PLANTED" = "$A_TOTAL" ] && [ "$A_TOTAL" -gt "$KEEP" ]; then
        fx_pass "N47a. the fixture is real: $A_TOTAL segments planted, above the KEEP of $KEEP"
    else
        fx_fail "N47a. the fixture is not usable — want $A_TOTAL planted segments above KEEP=$KEEP, got $A_PLANTED"
    fi
    if [ "$A_AFTER" = "$KEEP" ] && [ "$A_C" = "$A_CUR" ] && [ "$A_O" = "$A_OLD_LEFT" ] && \
       [ "$A_LASTO" = "$A_OLD" ]; then
        fx_pass "N47. all $A_CUR current-generation segments survived; the sweep spent $((A_OLD - A_OLD_LEFT)) old ones and kept the $A_OLD_LEFT newest old, leaving $KEEP"
    else
        fx_fail "N47. want $KEEP survivors with all $A_CUR current alive, $A_OLD_LEFT old alive and old #$A_OLD among them, got total=$A_AFTER current-alive=$A_C old-alive=$A_O newest-old-alive=$A_LASTO"
    fi
fi

# ===========================================================================
# N48 — past KEEP current writers, the survivors are still the newest current ones
# ===========================================================================
# The plan accepts data loss beyond KEEP concurrent writers. What must NOT happen is an old
# segment outliving a current one, so the whole survivor set is pinned here.
B_OLD=4
B_CUR=$((KEEP + 4))
B_FIRST_ALIVE=$((B_CUR - KEEP + 1))

if lib_missing "N48. with $B_CUR current segments the survivors are the $KEEP newest, all current"; then :
elif [ -z "$HOST_TOK" ]; then
    fx_fail "N48. cannot build the fixture: the host token is empty"
else
    plant "$B_OLD" "$B_CUR"
    run_all_dur_sweep
    B_AFTER="$(fx_ledger_segments)"
    read -r B_O B_C B_FIRSTC B_LASTO <<<"$(survivors "$B_OLD" "$B_CUR")"

    if [ "$B_AFTER" = "$KEEP" ] && [ "$B_O" = "0" ] && [ "$B_C" = "$KEEP" ] && \
       [ "$B_FIRSTC" = "$B_FIRST_ALIVE" ]; then
        fx_pass "N48. every old segment was swept first and the $KEEP survivors are current #$B_FIRST_ALIVE..#$B_CUR"
    else
        fx_fail "N48. want $KEEP survivors, 0 old alive, $KEEP current alive starting at current #$B_FIRST_ALIVE, got total=$B_AFTER old-alive=$B_O current-alive=$B_C oldest-current-alive=$B_FIRSTC"
    fi
fi

fx_ledger_clear
fx_finish
