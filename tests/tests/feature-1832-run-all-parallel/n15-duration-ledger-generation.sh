#!/usr/bin/env bash
# n15-duration-ledger-generation.sh — retention keeps the newest value of every key across generations.
# Tests: bin/lib/run-all-durations.sh, bin/lib/run-all-durations-consolidate.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, ledger, retention, consolidate, TL2, scope:issue-specific
# WHY: #2079 S7b replaced the newest-16-segments trim with consolidation. Two generations sit on disk
# at once, sharing some keys: whatever their file order, the newer provenance must win every
# shared key, keys only the older generation knows must survive, and both generations must end
# up in exactly one base. The "now" is an argument, so the fixed stamps never expire by date.
# TL3 gap: a real months-old ledger consolidated during live concurrent writes — mitigated at
# WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category pwsh-required.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "n15-duration-ledger-generation"

DUR_LIB_REL="bin/lib/run-all-durations.sh"
DUR_LIB="$FX_REPO_ROOT/$DUR_LIB_REL"
CONS_LIB="$FX_REPO_ROOT/bin/lib/run-all-durations-consolidate.sh"
PAR_LIB="$FX_REPO_ROOT/bin/lib/run-all-parallelism.sh"

LIB_OK=0
if [ -f "$DUR_LIB" ] && [ -f "$PAR_LIB" ]; then
    # shellcheck source=/dev/null
    . "$PAR_LIB" 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$DUR_LIB" 2>/dev/null || true
    if ! command -v run_all_dur_consolidate >/dev/null 2>&1 && [ -f "$CONS_LIB" ]; then
        # shellcheck source=/dev/null
        . "$CONS_LIB" 2>/dev/null || true
    fi
    command -v run_all_dur_consolidate >/dev/null 2>&1 && LIB_OK=1
fi

lib_missing() {
    [ "$LIB_OK" = "1" ] && return 1
    fx_fail "$1 (implementation missing or unloadable: run_all_dur_consolidate)"
    return 0
}

SCHEMA="${RUN_ALL_DUR_SCHEMA:-2}"
HOST_TOK=""; RID=""; ATTR=""
AG="$FX_TMP_ROOT/agents-under-test"
mkdir -p "$AG"
if [ "$LIB_OK" = "1" ]; then
    HOST_TOK="$(run_all_dur_host_token 2>/dev/null || true)"
    RID="$(run_all_dur_repo_id "$AG" 2>/dev/null || true)"
    ATTR="$(run_all_os_attr 2>/dev/null || true)"
fi

NOW="20260310T120000"
OLD_DAY="20260302"
CUR_DAY="20260308"

seg() { printf '%s/dur.%s.%s.%s.log\n' "$(fx_ledger_dir)" "$SCHEMA" "$HOST_TOK" "$1"; }

# plant_closed <day> <n> <secs> — n closed segments; segment i holds shared/i.sh=<secs> and
# <day>/i.sh=i, so each generation also owns keys the other never wrote.
plant_closed() {
    local i
    for ((i = 1; i <= $2; i++)); do
        printf '#os %s\n%s|%s|shared/%s.sh\n%s|%s|%s/%s.sh\n' "$ATTR" "$RID" "$3" "$i" "$RID" "$i" "$1" "$i" \
            > "$(seg "${1}T0000$(printf '%02d' "$i")-$i.closed")"
    done
}

# state — "<bases> <other-entries> <shared-wins> <old-only> <cur-only>" over the whole ledger.
state() {
    local f b=0 o=0
    for f in "$(fx_ledger_dir)"/dur.*; do
        [ -e "$f" ] || continue
        case "${f##*/}" in
            *.closed.log|*.consolidating.log) o=$((o + 1)) ;;
            *-0[0-9].log) b=$((b + 1)) ;;
            *) o=$((o + 1)) ;;
        esac
    done
    printf '%s %s %s\n' "$b" "$o" "$(fx_ledger_cat | awk -F'|' -v od="$OLD_DAY" -v cd="$CUR_DAY" '
        NF == 3 { n[$3]++; v[$3] = $2 }
        END {
            s = 0; ol = 0; cu = 0
            for (k in n) {
                if (n[k] != 1) continue
                if (k ~ /^shared\// && v[k] == 7) s++
                if (index(k, od "/") == 1) ol++
                if (index(k, cd "/") == 1) cu++
            }
            print s, ol, cu
        }')"
}

# ===========================================================================
# N47 — two closed generations: the newer provenance wins each shared key
# ===========================================================================
# The older generation holds 6 segments (shared/1..6 = 1), the newer 4 (shared/1..4 = 7).
if lib_missing "N47. two closed generations fold into one base with the newer values winning"; then :
elif [ -z "$HOST_TOK" ] || [ -z "$RID" ] || [ -z "$ATTR" ]; then
    fx_fail "N47. cannot build the fixture: token='$HOST_TOK' repo-id='$RID' attr='$ATTR'"
else
    fx_ledger_clear; mkdir -p "$(fx_ledger_dir)"
    plant_closed "$OLD_DAY" 6 1
    plant_closed "$CUR_DAY" 4 7
    A_PLANTED="$(fx_ledger_segments)"
    run_all_dur_consolidate "$(fx_ledger_dir)" "$NOW"
    read -r A_B A_O A_S A_OL A_CU <<<"$(state)"
    A_OLD_SHARED="$(fx_ledger_cat | awk -F'|' '$3 ~ /^shared\/[56]\.sh$/ && $2 == 1' | grep -c '' || true)"
    if [ "$A_PLANTED" = "10" ]; then
        fx_pass "N47a. the fixture is real: 10 closed segments planted across two generations"
    else
        fx_fail "N47a. the fixture is not usable — want 10 planted segments, got $A_PLANTED"
    fi
    if [ "$A_B" = "1" ] && [ "$A_O" = "0" ]; then
        fx_pass "N47. both generations folded into exactly one base and no closed segment is left"
    else
        fx_fail "N47. want 1 base and nothing else, got bases=$A_B other-entries=$A_O"
    fi
    if [ "$A_S" = "4" ] && [ "$A_OLD_SHARED" = "2" ] && [ "$A_OL" = "6" ] && [ "$A_CU" = "4" ]; then
        fx_pass "N47b. shared/1..4 kept the newer value 7 once each, shared/5..6 and every generation-own key survived"
    else
        fx_fail "N47b. want 4 newer shared wins, 2 older-only shared keys, 6 old-own and 4 current-own keys, got $A_S / $A_OLD_SHARED / $A_OL / $A_CU"
    fi
fi

# ===========================================================================
# N48 — an older base plus newer closed segments: the base is rewritten, not kept beside
# ===========================================================================
# The base carries the older generation under its own `#run` provenance; the newer closed
# segments must win the shared keys while the base-only keys stay readable.
if lib_missing "N48. an older base and newer closed segments become one base, newer values winning"; then :
elif [ -z "$HOST_TOK" ] || [ -z "$RID" ] || [ -z "$ATTR" ]; then
    fx_fail "N48. cannot build the fixture: token='$HOST_TOK' repo-id='$RID' attr='$ATTR'"
else
    fx_ledger_clear; mkdir -p "$(fx_ledger_dir)"
    OLD_BASE="$(seg "${OLD_DAY}T000006-01")"
    {
        printf '#os %s\n#run %sT000006-6\n' "$ATTR" "$OLD_DAY"
        for i in 1 2 3 4 5 6; do printf '%s|1|shared/%s.sh\n%s|%s|%s/%s.sh\n' "$RID" "$i" "$RID" "$i" "$OLD_DAY" "$i"; done
    } > "$OLD_BASE"
    plant_closed "$CUR_DAY" 4 7
    run_all_dur_consolidate "$(fx_ledger_dir)" "$NOW"
    read -r B_B B_O B_S B_OL B_CU <<<"$(state)"
    if [ "$B_B" = "1" ] && [ "$B_O" = "0" ] && [ ! -e "$OLD_BASE" ]; then
        fx_pass "N48. the older base and the closed segments became one new base"
    else
        fx_fail "N48. want 1 base, nothing else and the older base name gone, got bases=$B_B other-entries=$B_O old-base-left=$([ -e "$OLD_BASE" ] && echo yes || echo no)"
    fi
    if [ "$B_S" = "4" ] && [ "$B_OL" = "6" ] && [ "$B_CU" = "4" ]; then
        fx_pass "N48b. shared/1..4 took the newer value once each and every base-only key survived"
    else
        fx_fail "N48b. want 4 newer shared wins, 6 base-own and 4 current-own keys, got $B_S / $B_OL / $B_CU"
    fi
fi

fx_ledger_clear
fx_finish
