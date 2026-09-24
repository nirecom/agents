#!/usr/bin/env bash
# n14-duration-ledger-host-scope.sh — the host token really varies with the host, and hides it.
# Tests: bin/lib/run-all-durations.sh, bin/lib/run-all-parallelism.sh, tests/run-all.sh
# Tags: tests, bin, parallel, ledger, host-identity, privacy, TL2, scope:issue-specific
# WHY: every sibling case reads run_all_dur_host_token exactly once per process, so a function
# hard-coded to a constant would pass all of them — segments would simply be shared across
# machines on a synced home directory. The token is therefore driven here: HOSTNAME is varied
# with the memo cleared between calls, and the raw hostname is checked never to appear in the
# token or anywhere in the ledger, because run_all_host_id digests it deliberately.
# TL3 gap: a host with no HOSTNAME where `uname -n` is the source — mitigated at
# WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category pwsh-required.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "n14-duration-ledger-host-scope"

DUR_LIB_REL="bin/lib/run-all-durations.sh"
DUR_LIB="$FX_REPO_ROOT/$DUR_LIB_REL"
PAR_LIB="$FX_REPO_ROOT/bin/lib/run-all-parallelism.sh"

LIB_OK=0
if [ -f "$DUR_LIB" ] && [ -f "$PAR_LIB" ]; then
    # shellcheck source=/dev/null
    . "$PAR_LIB" 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$DUR_LIB" 2>/dev/null || true
    command -v run_all_dur_host_token >/dev/null 2>&1 && LIB_OK=1
fi

lib_missing() {
    [ "$LIB_OK" = "1" ] && return 1
    fx_fail "$1 (implementation missing or unloadable: $DUR_LIB_REL)"
    return 0
}

WIDTH="${RUN_ALL_DUR_TOKEN_WIDTH:-16}"
HOST_A="fxhostalphamarker"
HOST_B="fxhostbetamarker"

# The token is memoised in RUN_ALL_DUR_HOST_TOKEN, so each probe runs in its own subshell
# with the memo cleared — otherwise the first value would be echoed back for every hostname.
token_for() {
    (
        RUN_ALL_DUR_HOST_TOKEN=""
        HOSTNAME="$1"
        export HOSTNAME
        run_all_dur_host_token 2>/dev/null || printf '%s' "${RUN_ALL_DUR_HOST_TOKEN:-}"
    )
}

# ===========================================================================
# N45 — same host stable, different host different, never a constant
# ===========================================================================
if lib_missing "N45. the host token is stable per host and differs between hosts"; then
    fx_fail "N45b. the token is a fixed-width alphanumeric that never contains the hostname (implementation missing or unloadable: $DUR_LIB_REL)"
else
    T_A1="$(token_for "$HOST_A")"
    T_A2="$(token_for "$HOST_A")"
    T_B="$(token_for "$HOST_B")"

    if [ -n "$T_A1" ] && [ "$T_A1" = "$T_A2" ] && [ "$T_A1" != "$T_B" ] && [ -n "$T_B" ]; then
        fx_pass "N45. HOSTNAME=$HOST_A resolved the same token twice and HOSTNAME=$HOST_B resolved a different one"
    else
        fx_fail "N45. want a stable token for one hostname and a different token for another, got A1='${T_A1:-empty}' A2='${T_A2:-empty}' B='${T_B:-empty}'"
    fi

    BAD=""
    for T in "$T_A1" "$T_B"; do
        [ "${#T}" -eq "$WIDTH" ] || BAD="$BAD width($T=${#T})"
        case "$T" in *[!A-Za-z0-9]*) BAD="$BAD class($T)" ;; esac
        case "$T" in "0000000000000000") BAD="$BAD all-padding($T)" ;; esac
        case "$T" in *"$HOST_A"*|*"$HOST_B"*) BAD="$BAD leaks-hostname($T)" ;; esac
    done
    if [ -z "$BAD" ]; then
        fx_pass "N45b. both tokens are $WIDTH alphanumeric characters, neither all-padding nor containing the hostname"
    else
        fx_fail "N45b. token shape violations:$BAD"
    fi
fi

# ===========================================================================
# N46 — a real run never writes the raw hostname anywhere in the ledger
# ===========================================================================
# The hostname is a machine identifier the ledger must digest, not store. This asserts it
# against a real run, over segment CONTENT and segment NAMES alike.
M="$(fx_new_root)"
fx_add_dummy "$M" m1 --sleep 1
fx_add_dummy "$M" m2 --sleep 1
M_OUT="$FX_TMP_ROOT/m.out"; M_ERR="$FX_TMP_ROOT/m.err"

OLD_HOSTNAME_SET="${HOSTNAME+set}"
OLD_HOSTNAME="${HOSTNAME:-}"
HOSTNAME="$HOST_A"
export HOSTNAME
fx_exec "$M" 90 "$M_OUT" "$M_ERR" -j 2 --all
M_RC=$?
if [ "$OLD_HOSTNAME_SET" = "set" ]; then
    HOSTNAME="$OLD_HOSTNAME"
    export HOSTNAME
else
    unset HOSTNAME
fi

M_EXEC="$(fx_contract_field "$M_OUT" EXECUTED)"
M_SEGS="$(fx_ledger_segments)"
CONTENT_HITS="$(fx_ledger_cat | grep -cF "$HOST_A" || true)"
NAME_HITS=0
for f in "$(fx_ledger_dir)"/dur.*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in *"$HOST_A"*) NAME_HITS=$((NAME_HITS + 1)) ;; esac
done

if [ "$M_RC" -eq 0 ] && [ "$M_EXEC" = "2" ] && [ "$M_SEGS" = "1" ]; then
    fx_pass "N46a. the fixture is real: a run under HOSTNAME=$HOST_A left one segment with EXECUTED=2"
else
    fx_fail "N46a. the fixture is not usable — want exit 0, EXECUTED=2 and 1 segment, got exit $M_RC EXECUTED=${M_EXEC:-absent} segments=$M_SEGS"
    fx_show_tail "$M_ERR" 6
fi

if [ ! -f "$DUR_LIB" ]; then
    fx_fail "N46. the raw hostname never appears in the ledger (implementation missing: $DUR_LIB_REL)"
elif [ "$M_SEGS" = "1" ] && [ "$CONTENT_HITS" = "0" ] && [ "$NAME_HITS" = "0" ]; then
    fx_pass "N46. the raw hostname '$HOST_A' appears in no segment name and in no record, so it was digested"
else
    fx_fail "N46. want 0 hostname occurrences in segment names and records over 1 segment, got segments=$M_SEGS content-hits=$CONTENT_HITS name-hits=$NAME_HITS"
fi

fx_ledger_clear
fx_finish
