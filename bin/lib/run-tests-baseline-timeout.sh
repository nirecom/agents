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
# shellcheck source=bin/lib/run-all-classify.sh
. "$RTB_TIMEOUT_LIB_DIR/run-all-classify.sh" || return 1

RTB_TIMEOUT_DEFAULT=300
RTB_TIMEOUT_MARGIN_FACTOR=2
RTB_TIMEOUT_CAP=540
RTB_BUDGET_CEIL=600
# Test seam; normalised at use, never above RTB_BUDGET_CEIL.
: "${RTB_BUDGET_TOTAL:=600}"
RTB_BUDGET_SAFETY=45
RTB_BUDGET_KILL_GRACE=2
RTB_BUDGET_MIN_SLICE=30

declare -ga RTB_TIMEOUT_LEDGER=() RTB_TIMEOUT_LEDGER_TERM=()
RTB_TIMEOUT_DERIVED_OUT=""
RTB_TIMEOUT_REQUESTED_OUT=""
RTB_TIMEOUT_SRC_OUT=""
RTB_TIMEOUT_APPLIED_OUT=""
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
# seconds and RTB_TIMEOUT_LEDGER_TERM[idx] = the termination of that same (newest) line; unmeasured,
# empty or non-numeric entries stay unset. Called once per baseline run, at its start.
rtb_timeout_load_ledger() {
    local root="${1:-}" wd="${2:-}" item id s keys secs term
    RTB_TIMEOUT_LEDGER=() RTB_TIMEOUT_LEDGER_TERM=()
    [ -n "$root" ] && [ -n "$wd" ] && shift 2 || return 0
    # Per-process names: concurrent baseline runs may share the work directory.
    keys="$wd/timeout.$$.keys" secs="$wd/timeout.$$.secs" term="$wd/timeout.$$.term"
    rm -f "$secs" "$term"
    : >"$keys" 2>/dev/null || return 0
    for item in "$@"; do
        run_all_dur_key_into "$root/${item#*:}" "$root" || continue
        if [ -n "$RUN_ALL_DUR_KEY_OUT" ]; then
            printf '%s\t%s\n' "${item%%:*}" "$RUN_ALL_DUR_KEY_OUT"
        fi
    done >"$keys"
    run_all_dur_lookup "$root" "$keys" "$secs" "$term"
    [ -f "$secs" ] || return 0
    while IFS="$(printf '\t')" read -r id s; do
        case "$id" in ''|*[!0-9]*) continue ;; esac
        case "$s" in ''|*[!0-9]*) continue ;; esac
        RTB_TIMEOUT_LEDGER[id]="$s"
    done <"$secs"
    [ -f "$term" ] || return 0
    while IFS="$(printf '\t')" read -r id s; do
        case "$id" in ''|*[!0-9]*) continue ;; esac
        [ -n "${RTB_TIMEOUT_LEDGER[id]:-}" ] || continue
        [[ "$s" =~ ^[A-Za-z0-9?_-]+$ ]] || continue
        # shellcheck disable=SC2034  # outputs read by the sourcing caller
        RTB_TIMEOUT_LEDGER_TERM[id]="$s"
    done <"$term"
    return 0
}

# rtb_timeout_lang_cap_into <rel> — RTB_TIMEOUT_LANG_CAP_OUT = launch.timeoutSeconds of the registry
# entry matching <rel> in this checkout's loaded registry; empty for null, no match or no registry.
# shellcheck disable=SC2034  # read by the branch / classify stages
rtb_timeout_lang_cap_into() {
    RTB_TIMEOUT_LANG_CAP_OUT=""
    declare -F tlr_match >/dev/null 2>&1 && tlr_match "${1:-}" || return 0
    _tlr_get "$TLR_ID" launch.timeoutSeconds || return 0
    [[ "$_TLR_V" =~ ^[1-9][0-9]{0,8}$ ]] && RTB_TIMEOUT_LANG_CAP_OUT="$_TLR_V"
    return 0
}

# rtb_timeout_effective_into <secs> <cap> — RAC_EFFECTIVE_TIMEOUT = min(secs, cap), as the launcher
# applies it; the prefix assignment holds for this one call only, so an ambient value never counts.
rtb_timeout_effective_into() {
    RUN_ALL_TIMEOUT_SECONDS="${1:-}" rac_effective_timeout "${2:-}"
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

# rtb_timeout_requested_into <ledger-secs|""> <explicit|""> — RTB_TIMEOUT_DERIVED_OUT,
# RTB_TIMEOUT_REQUESTED_OUT (REQUESTED_TEST_TIMEOUT: the explicit value, else the derived one) and
# RTB_TIMEOUT_SRC_OUT (explicit / default / derived).
# shellcheck disable=SC2034  # outputs read by the sourcing caller
rtb_timeout_requested_into() {
    rtb_timeout_derive_into "${1:-}"
    if [ -n "${2:-}" ]; then
        RTB_TIMEOUT_REQUESTED_OUT="$2" RTB_TIMEOUT_SRC_OUT="explicit"
    elif [ -n "${1:-}" ]; then
        RTB_TIMEOUT_REQUESTED_OUT="$RTB_TIMEOUT_DERIVED_OUT" RTB_TIMEOUT_SRC_OUT="derived"
    else
        RTB_TIMEOUT_REQUESTED_OUT="$RTB_TIMEOUT_DERIVED_OUT" RTB_TIMEOUT_SRC_OUT="default"
    fi
}

# rtb_timeout_budget_into <requested> <elapsed> — RTB_TIMEOUT_APPLIED_OUT (APPLIED_TEST_TIMEOUT) =
# min(requested, remaining); 0 when less than RTB_BUDGET_MIN_SLICE remains (budget exhausted).
# An empty <requested> yields the remaining time itself. The sole budget clamp.
rtb_timeout_budget_into() {
    local total elapsed remaining requested
    rtb_timeout_num_into "$RTB_BUDGET_TOTAL" "$RTB_BUDGET_CEIL" "$RTB_BUDGET_CEIL"
    total="$RTB_TIMEOUT_NUM_OUT"
    [ "$total" -le "$RTB_BUDGET_CEIL" ] || total="$RTB_BUDGET_CEIL"
    rtb_timeout_num_into "${2:-}" 0 "$RTB_BUDGET_CEIL"
    elapsed="$RTB_TIMEOUT_NUM_OUT"
    remaining=$((total - RTB_BUDGET_SAFETY - elapsed - RTB_BUDGET_KILL_GRACE))
    if [ "$remaining" -lt "$RTB_BUDGET_MIN_SLICE" ]; then
        RTB_TIMEOUT_APPLIED_OUT=0
        return 0
    fi
    rtb_timeout_num_into "${1:-}" "$remaining" "$remaining"
    requested="$RTB_TIMEOUT_NUM_OUT"
    [ "$requested" -le "$remaining" ] || requested="$remaining"
    # shellcheck disable=SC2034
    RTB_TIMEOUT_APPLIED_OUT="$requested"
}

# rtb_timeout_recordable <applied> <requested> <derived> [<lang-cap>] — 0 when a timeout may be
# recorded: the budget did not shorten it below the effective requested value (both capped by
# <lang-cap>, #3035) and the raw requested value is not below the derived one (#3015).
rtb_timeout_recordable() {
    local a r d
    rtb_timeout_num_into "${1:-}" "" ""; a="$RTB_TIMEOUT_NUM_OUT"
    rtb_timeout_num_into "${2:-}" "" ""; r="$RTB_TIMEOUT_NUM_OUT"
    rtb_timeout_num_into "${3:-}" "" ""; d="$RTB_TIMEOUT_NUM_OUT"
    [ -n "$a" ] && [ -n "$r" ] && [ -n "$d" ] && [ "$r" -gt 0 ] && [ "$r" -ge "$d" ] || return 1
    rtb_timeout_effective_into "$a" "${4:-}"; a="$RAC_EFFECTIVE_TIMEOUT"
    rtb_timeout_effective_into "$r" "${4:-}"; r="$RAC_EFFECTIVE_TIMEOUT"
    [ -n "$a" ] && [ -n "$r" ] && [ "$a" -ge "$r" ]
}

# rtb_timeout_settle_into <idx> <reserve-secs> — how a test the budget left undecided settles:
# RTB_TIMEOUT_SETTLE_OUT exceeds-budget when its newest duration-ledger line is completed and above
# RTB_TIMEOUT_SETTLE_LIMIT (the stage's whole budget less <reserve-secs>, never elapsed time), else
# budget-exhausted; RTB_TIMEOUT_SETTLE_WHY exceeds / unmeasured / not-completed:<term> / within-limit.
# Reads only what rtb_timeout_load_ledger loaded at the call's start; baseline never writes that ledger.
# shellcheck disable=SC2034  # RTB_TIMEOUT_SETTLE_OUT is read by the callers
rtb_timeout_settle_into() {
    local i="${1:-}" saved="$RTB_TIMEOUT_APPLIED_OUT" s t
    rtb_timeout_budget_into "" "${2:-0}"
    RTB_TIMEOUT_SETTLE_LIMIT="$RTB_TIMEOUT_APPLIED_OUT"
    RTB_TIMEOUT_APPLIED_OUT="$saved"
    RTB_TIMEOUT_SETTLE_OUT="budget-exhausted"
    s="${RTB_TIMEOUT_LEDGER[i]:-}" t="${RTB_TIMEOUT_LEDGER_TERM[i]:-}"
    RTB_TIMEOUT_SETTLE_SECS="$s"
    if [[ ! "$s" =~ ^[0-9]+$ ]]; then
        RTB_TIMEOUT_SETTLE_WHY="unmeasured"
    elif [[ "$t" != "completed" ]]; then
        RTB_TIMEOUT_SETTLE_WHY="not-completed:$t"
    elif [[ "${#s}" -le 9 && "$((10#$s))" -le "$RTB_TIMEOUT_SETTLE_LIMIT" ]]; then
        RTB_TIMEOUT_SETTLE_WHY="within-limit"
    else
        RTB_TIMEOUT_SETTLE_OUT="exceeds-budget" RTB_TIMEOUT_SETTLE_WHY="exceeds"
    fi
    return 0
}

# rtb_timeout_settle_note <t> [<requested> <derived> <applied-max>] — one stderr line for the
# rtb_timeout_settle_into result just computed for <t>; a within-limit result (or an explicit value
# below the derived one) keeps rtb_timeout_unrecordable_note's line.
rtb_timeout_settle_note() {
    case "$RTB_TIMEOUT_SETTLE_WHY" in
        exceeds)
            printf 'run-tests-baseline: exceeds budget: %s measured %ss > %ss per call; auto-accepted, listed under Unverified tests\n' \
                "$1" "$RTB_TIMEOUT_SETTLE_SECS" "$RTB_TIMEOUT_SETTLE_LIMIT" >&2 ;;
        within-limit) rtb_timeout_unrecordable_note "$@" ;;
        *)
            if [ "${2:-0}" -lt "${3:-0}" ] 2>/dev/null; then
                rtb_timeout_unrecordable_note "$@"
            else
                printf 'run-tests-baseline: budget-exhausted: %s has no completed measurement (%s); let /run-tests run it to completion, or fix it if it hangs\n' \
                    "$1" "$RTB_TIMEOUT_SETTLE_WHY" >&2
            fi ;;
    esac
    return 0
}

# rtb_timeout_unrecordable_note <t> <requested> <derived> <applied-max|""> — one stderr line when
# the timeout can never be recorded as asked, naming the way out; silent for a budget cut.
rtb_timeout_unrecordable_note() {
    local why=""
    if [ "${2:-0}" -lt "${3:-0}" ] 2>/dev/null; then
        why="explicit --per-test-timeout is below the derived ${3}s: drop it or raise it"
    elif [ -n "${4:-}" ] && [ "${2:-0}" -gt "$4" ] 2>/dev/null; then
        why="the branch stage applies at most ${4}s: shorten or split the test"
    fi
    [ -z "$why" ] || printf 'run-tests-baseline: timeout not recorded: %s requested %ss; %s\n' "$1" "$2" "$why" >&2
    return 0
}
