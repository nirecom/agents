#!/usr/bin/env bash
# Per-test timeout for bin/run-tests-baseline (#2547). Source-only.
# The timeout is derived from the duration ledger (measured seconds x margin, clamped to
# [DEFAULT, CAP]; unmeasured -> DEFAULT), and every timeout, derived or explicit, is clamped by
# one budget so the whole re-run loop ends inside a single 600 s Bash call.
# Depends only on run-tests-baseline-ledger.sh, which owns the parallelism -> durations order.
# Read-only on the ledger: the writer is never initialised here.

case "${BASH_SOURCE[0]}" in
  */*) RTB_TIMEOUT_LIB_DIR="${BASH_SOURCE[0]%/*}" ;;
  *)   RTB_TIMEOUT_LIB_DIR="." ;;
esac
# shellcheck source=bin/lib/run-tests-baseline-ledger.sh
. "$RTB_TIMEOUT_LIB_DIR/run-tests-baseline-ledger.sh" || return 1

RTB_TIMEOUT_DEFAULT=300
RTB_TIMEOUT_MARGIN_FACTOR=2
RTB_TIMEOUT_CAP=540
RTB_BUDGET_CEIL=600
# Test seam; normalised at use, never above RTB_BUDGET_CEIL.
: "${RTB_BUDGET_TOTAL:=600}"
RTB_BUDGET_SAFETY=45
RTB_BUDGET_KILL_GRACE=2
RTB_BUDGET_MIN_SLICE=30

declare -ga RTB_TIMEOUT_LEDGER=()
RTB_TIMEOUT_DERIVED_OUT=""
RTB_TIMEOUT_SLICE_OUT=""
RTB_TIMEOUT_NUM_OUT=""

# rtb_timeout_num_into <value> <if-invalid> <if-huge> — a decimal of at most 9 digits as is;
# a longer digit string -> <if-huge>; anything else (empty, sign, letters) -> <if-invalid>.
rtb_timeout_num_into() {
    case "${1:-}" in
        ''|*[!0-9]*) RTB_TIMEOUT_NUM_OUT="$2" ;;
        *) if [ "${#1}" -gt 9 ]; then RTB_TIMEOUT_NUM_OUT="$3"; else RTB_TIMEOUT_NUM_OUT=$((10#$1)); fi ;;
    esac
}

# rtb_timeout_load_ledger <root> <workdir> <idx>:<rel>... — RTB_TIMEOUT_LEDGER[idx] = measured
# seconds; unmeasured, empty or non-numeric entries stay unset.
rtb_timeout_load_ledger() {
    local root="${1:-}" wd="${2:-}" item id s
    RTB_TIMEOUT_LEDGER=()
    [ -n "$root" ] && [ -n "$wd" ] && shift 2 || return 0
    : >"$wd/timeout.keys" 2>/dev/null || return 0
    for item in "$@"; do
        run_all_dur_key_into "$root/${item#*:}" "$root" || continue
        if [ -n "$RUN_ALL_DUR_KEY_OUT" ]; then
            printf '%s\t%s\n' "${item%%:*}" "$RUN_ALL_DUR_KEY_OUT"
        fi
    done >"$wd/timeout.keys"
    run_all_dur_lookup "$root" "$wd/timeout.keys" "$wd/timeout.secs"
    [ -f "$wd/timeout.secs" ] || return 0
    while IFS="$(printf '\t')" read -r id s; do
        case "$id" in ''|*[!0-9]*) continue ;; esac
        case "$s" in ''|*[!0-9]*) continue ;; esac
        # shellcheck disable=SC2034  # outputs read by the sourcing caller
        RTB_TIMEOUT_LEDGER[id]="$s"
    done <"$wd/timeout.secs"
    return 0
}

# rtb_timeout_derive_into <secs-or-empty> — RTB_TIMEOUT_DERIVED_OUT.
rtb_timeout_derive_into() {
    local v
    rtb_timeout_num_into "${1:-}" "" "$RTB_TIMEOUT_CAP"
    if [ -z "$RTB_TIMEOUT_NUM_OUT" ]; then
        RTB_TIMEOUT_DERIVED_OUT="$RTB_TIMEOUT_DEFAULT"
        return 0
    fi
    v=$((RTB_TIMEOUT_NUM_OUT * RTB_TIMEOUT_MARGIN_FACTOR))
    [ "$v" -ge "$RTB_TIMEOUT_DEFAULT" ] || v="$RTB_TIMEOUT_DEFAULT"
    [ "$v" -le "$RTB_TIMEOUT_CAP" ] || v="$RTB_TIMEOUT_CAP"
    RTB_TIMEOUT_DERIVED_OUT="$v"
}

# rtb_timeout_budget_into <wanted> <elapsed> — RTB_TIMEOUT_SLICE_OUT = min(wanted, remaining);
# 0 when less than RTB_BUDGET_MIN_SLICE remains (budget exhausted). The sole budget clamp.
rtb_timeout_budget_into() {
    local total elapsed remaining wanted
    rtb_timeout_num_into "$RTB_BUDGET_TOTAL" "$RTB_BUDGET_CEIL" "$RTB_BUDGET_CEIL"
    total="$RTB_TIMEOUT_NUM_OUT"
    [ "$total" -le "$RTB_BUDGET_CEIL" ] || total="$RTB_BUDGET_CEIL"
    rtb_timeout_num_into "${2:-}" 0 "$RTB_BUDGET_CEIL"
    elapsed="$RTB_TIMEOUT_NUM_OUT"
    remaining=$((total - RTB_BUDGET_SAFETY - elapsed - RTB_BUDGET_KILL_GRACE))
    if [ "$remaining" -lt "$RTB_BUDGET_MIN_SLICE" ]; then
        RTB_TIMEOUT_SLICE_OUT=0
        return 0
    fi
    rtb_timeout_num_into "${1:-}" "$remaining" "$remaining"
    wanted="$RTB_TIMEOUT_NUM_OUT"
    [ "$wanted" -le "$remaining" ] || wanted="$remaining"
    # shellcheck disable=SC2034
    RTB_TIMEOUT_SLICE_OUT="$wanted"
}

# rtb_timeout_slice_into <secs-or-empty> <elapsed> — derive, then clamp by the budget.
rtb_timeout_slice_into() {
    rtb_timeout_derive_into "${1:-}"
    rtb_timeout_budget_into "$RTB_TIMEOUT_DERIVED_OUT" "${2:-}"
}
