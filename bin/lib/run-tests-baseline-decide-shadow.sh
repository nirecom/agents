# shellcheck shell=bash
# bin/lib/run-tests-baseline-decide-shadow.sh — shadow of decide (#3068). Source-only.
# (a) rtb_decide_shadow_install: wraps rtb_exec_one and appends one line per call with its comparison side result
#     to the capture file (return value, RTB_EXEC_*, and stdin stay unchanged).
# (b) rtb_decide_shadow_compare_before_handoff: before the handoff to state, checks decide against live and
#     writes the divergence log plus one stderr line. Never touches CLS / DET, the classification file, stdout, or exit.
# kill switch: RUN_TESTS_BASELINE_DECIDE_SHADOW=off makes both (a) and (b) no-ops.
# test seam: RUN_TESTS_BASELINE_DECIDE_SHADOW_FAULT_FOR_TEST=fail|hang (takes effect only inside the background subshell of (b)).

RTB_DECIDE_SHADOW_JS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-tests-baseline-decide-shadow.js"
RTB_DECIDE_SHADOW_CAPTURE_FILE="${RTB_DECIDE_SHADOW_CAPTURE_FILE:-}"
# A capture file named by the environment belongs to the caller, so (b) never deletes it.
RTB_DECIDE_SHADOW_CAPTURE_FROM_ENV=0
[[ -z "$RTB_DECIDE_SHADOW_CAPTURE_FILE" ]] || RTB_DECIDE_SHADOW_CAPTURE_FROM_ENV=1
RTB_DECIDE_SHADOW_HEADER='# run-tests-baseline decide shadow v1'
# Cap for (b), and the seconds kept in reserve for the handoff and output (detail.md "time, budget, and outer time limit of (b)").
RTB_DECIDE_SHADOW_CAP_SECONDS=10
RTB_DECIDE_SHADOW_RESERVE_SECONDS=15

_rtb_decide_shadow_off() { [[ "${RUN_TESTS_BASELINE_DECIDE_SHADOW:-}" == off ]]; }

rtb_decide_shadow_install() {
    local def
    _rtb_decide_shadow_off && return 0
    declare -F rtb_exec_one >/dev/null 2>&1 || return 0
    # A second install must not wrap the wrapper in another wrapper.
    declare -F rtb_exec_one_unwrapped >/dev/null 2>&1 && return 0
    def="$(declare -f rtb_exec_one)" || return 0
    eval "rtb_exec_one_unwrapped${def#rtb_exec_one}"
    # shellcheck disable=SC2329  # called by the live CLI (only redefined here)
    rtb_exec_one() {
        local _rtb_ds_rc=0
        rtb_exec_one_unwrapped "$@" || _rtb_ds_rc=$?
        _rtb_decide_shadow_capture "$_rtb_ds_rc" "$@"
        return "$_rtb_ds_rc"
    }
    return 0
}

# _rtb_decide_shadow_capture <rc> <wt> <rel> <timeout> <logdir> — append failures are discarded (never stop live).
_rtb_decide_shadow_capture() {
    local side=merge-base rel
    if [[ -z "$RTB_DECIDE_SHADOW_CAPTURE_FILE" ]]; then
        [[ -n "${LOGDIR:-}" ]] || return 0
        RTB_DECIDE_SHADOW_CAPTURE_FILE="${LOGDIR}.decide-shadow-capture.tsv"
    fi
    if [[ "${2:-}" == "${ROOT:-}" ]]; then side=branch; fi
    _rtb_decide_shadow_escape rel "${3:-}"
    { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$side" "$rel" "${5:-}" "${RTB_EXEC_SEQ:-}" "$1" \
        "${RTB_EXEC_RC:-}" "${RTB_EXEC_TIMEDOUT:-}" "${RTB_EXEC_UNSUPPORTED:-}" "${RTB_EXEC_DECOY:-}" \
        "${RTB_EXEC_STATE:-}" "${RTB_EXEC_UNRUNNABLE:-}" >>"$RTB_DECIDE_SHADOW_CAPTURE_FILE"; } 2>/dev/null || :
    return 0
}

# _rtb_decide_shadow_escape <var> <path> — sets <var> to <path> with backslash, TAB, and newline written as \\, \t, \n
# so a path stays one TSV column. No subshell: the capture append on the live path calls it.
_rtb_decide_shadow_escape() {
    local _rtb_ds_bs=$'\\' _rtb_ds_esc="${2:-}"
    _rtb_ds_esc="${_rtb_ds_esc//"$_rtb_ds_bs"/"$_rtb_ds_bs$_rtb_ds_bs"}"
    _rtb_ds_esc="${_rtb_ds_esc//$'\t'/"${_rtb_ds_bs}t"}"
    _rtb_ds_esc="${_rtb_ds_esc//$'\n'/"${_rtb_ds_bs}n"}"
    printf -v "$1" '%s' "$_rtb_ds_esc"
}

# Current time (ms). Falls back to second precision on a bash without EPOCHREALTIME.
_rtb_decide_shadow_ms() {
    local t="${EPOCHREALTIME:-}"
    if [[ "$t" =~ ^([0-9]+)[.,]([0-9]{3}) ]]; then printf '%s' "${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    else printf '%s000' "$(date +%s)"; fi
}

# Remaining budget (seconds). Only reads the timeout lib's values, never calls its functions (#3093).
_rtb_decide_shadow_remaining() {
    local ceil="${RTB_BUDGET_CEIL:-600}" total="${RTB_BUDGET_TOTAL:-}"
    case "$total" in ''|*[!0-9]*|??????????*) total="$ceil" ;; esac
    total=$((10#$total))
    [[ "$total" -le "$ceil" ]] || total="$ceil"
    printf '%s' "$((total - SECONDS))"
}

# Writes a copy of the capture with the logdir column in native form; Git Bash /tmp/... is elsewhere for Node fs.
# The capture append (the live path) never calls cygpath; conversion happens here, once per logdir.
_rtb_decide_shadow_native_capture() {
    local src="$1" dst="$2" line head logdir rest
    local -A native=()
    : >"$dst" || return 1
    [[ -f "$src" ]] || return 0
    # IFS treats tab as whitespace and collapses empty columns, so split by expansion, not by read.
    while IFS= read -r line; do
        head="${line%%$'\t'*}"; rest="${line#*$'\t'}"
        head+=$'\t'"${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
        logdir="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
        [[ -n "${native[$logdir]+x}" ]] || native[$logdir]="$(rtb_wt_native "$logdir")"
        printf '%s\t%s\t%s\n' "$head" "${native[$logdir]}" "$rest" >>"$dst"
    done <"$src"
}

# First step of the background subshell, so it runs under the cap: log retention, then the input TSV.
# CLS / DET are read here from the copy the forked subshell got; the parent's arrays are never touched.
_rtb_decide_shadow_prepare() {
    local dir="$1" inp="$2" i t r o
    find "$dir" -maxdepth 1 -type f -name 'divergence-*.tsv' -mmin +$((${RTB_LEDGER_RETENTION_DAYS:-30} * 1440)) \
        -exec rm -f {} + 2>/dev/null || :
    { for i in "${!TESTS[@]}"; do
        _rtb_decide_shadow_escape t "${TESTS[$i]}"
        _rtb_decide_shadow_escape r "${RUN_REL[i]:-}"
        _rtb_decide_shadow_escape o "${RUN_OLD[i]:-}"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$t" "$r" "$o" \
            "${CLS[i]:-}" "${DET[i]:-}" "${NEWC[i]:-0}" "${NEWH[i]:-[]}"
    done >"$inp"; } 2>/dev/null
}

# Body of the background subshell: writes the input, rename map, and per-test-file change status, then runs node once.
_rtb_decide_shadow_run() {
    local dir="$1" inp="$2" cap="$3" map="$4" tfc="$5" out="$6" log="$7" start="$8" i rc wt=""
    case "${RUN_TESTS_BASELINE_DECIDE_SHADOW_FAULT_FOR_TEST:-}" in
        fail) exit 1 ;;
        hang) sleep 60; exit 1 ;;
    esac
    _rtb_decide_shadow_prepare "$dir" "$inp" || exit 1
    : >"$map" || exit 1
    : >"$tfc" || exit 1
    if [[ -n "${B2:-}" ]]; then
        rtb_rename_pairs "$ROOT" "$B2" . >"$map" 2>/dev/null
        for i in "${!TESTS[@]}"; do
            [[ -n "${RUN_REL[i]:-}" ]] || continue
            rc=0
            if [[ -n "${RUN_OLD[i]:-}" ]]; then rtb_test_changed "$B2" "${TESTS[$i]}" "${RUN_OLD[i]}" || rc=$?
            else rtb_test_changed "$B2" "${TESTS[$i]}" || rc=$?; fi
            printf '%s\t%s\n' "$i" "$rc" >>"$tfc"
        done
    fi
    [[ -z "${WT:-}" ]] || wt="$(rtb_wt_native "$WT")"
    _rtb_decide_shadow_native_capture "$cap" "$cap.native"
    node "$(rtb_wt_native "$RTB_DECIDE_SHADOW_JS")" --input "$(rtb_wt_native "$inp")" --capture "$(rtb_wt_native "$cap.native")" \
        --map "$(rtb_wt_native "$map")" --tfc "$(rtb_wt_native "$tfc")" --root "$(rtb_wt_native "$ROOT")" \
        --base-wt "$wt" --b2 "${B2:-}" --head "${HEAD_SHA:-}" --log "$(rtb_wt_native "$log")" --started-ms "$start" >"$out"
}

# Log for an aborted run: counts every entry as no comparison and keeps the elapsed_ms measured by the shell.
_rtb_decide_shadow_skip_log() {
    local log="$1" reason="$2" elapsed="$3" i p
    {
        printf '%s\n' "$RTB_DECIDE_SHADOW_HEADER"
        printf 'RUN\t%s\t%s\t%s\n' "$(date +%s)" "${HEAD_SHA:-}" "${B2:--}"
        for i in "${!TESTS[@]}"; do
            _rtb_decide_shadow_escape p "${TESTS[$i]}"
            printf 'NO_COMPARISON\t%s\t%s\n' "$p" "$reason"
        done
        printf 'SUMMARY\tcompared=0\tmatched=0\trecorded=0\tunrecorded=0\tno_comparison=%s\tskipped=%s\telapsed_ms=%s\n' \
            "${#TESTS[@]}" "$reason" "$elapsed"
    } >"$log" 2>/dev/null || :
}

rtb_decide_shadow_compare_before_handoff() {
    _rtb_decide_shadow_off && return 0
    local start dir log pfx cap inp map tfc out flag reason="" counts="" cpid wpid restore_m=0 own
    start="$(_rtb_decide_shadow_ms)"
    dir="$(run_all_cache_dir 2>/dev/null)/baseline/decide-shadow"
    mkdir -p "$dir" 2>/dev/null || :
    log="$dir/divergence-${RUN_ALL_DUR_HOST_TOKEN:-host}-$(date +%s)-$$.tsv"
    pfx="${LOGDIR:-$dir/run-$$}"
    cap="${RTB_DECIDE_SHADOW_CAPTURE_FILE:-${pfx}.decide-shadow-capture.tsv}"
    inp="${pfx}.decide-shadow-input.tsv" map="${pfx}.decide-shadow-map.tsv" tfc="${pfx}.decide-shadow-tfc.tsv"
    out="${pfx}.decide-shadow-out.txt" flag="${pfx}.decide-shadow-timedout"
    rm -f "$flag" "$out" 2>/dev/null
    if [[ "$(_rtb_decide_shadow_remaining)" -lt $((RTB_DECIDE_SHADOW_CAP_SECONDS + RTB_DECIDE_SHADOW_RESERVE_SECONDS)) ]]; then
        reason=budget-short
    fi
    if [[ -z "$reason" ]]; then
        # Job control gives a separate process group so the watchdog can stop it together with node and git.
        case "$-" in *m*) ;; *) set -m; restore_m=1 ;; esac
        ( _rtb_decide_shadow_run "$dir" "$inp" "$cap" "$map" "$tfc" "$out" "$log" "$start" ) </dev/null >/dev/null 2>&1 &
        cpid=$!
        (
            sleep "$RTB_DECIDE_SHADOW_CAP_SECONDS"
            : >"$flag"
            rtb_exec_kill_group "$cpid" TERM
            sleep 2
            rtb_exec_kill_group "$cpid" KILL
        ) </dev/null >/dev/null 2>&1 &
        wpid=$!
        if [[ "$restore_m" -eq 1 ]]; then set +m; fi
        wait "$cpid" 2>/dev/null || :
        rtb_exec_kill_group "$wpid" TERM
        wait "$wpid" 2>/dev/null || :
        counts="$(head -n 1 "$out" 2>/dev/null)" || counts=""
        if [[ -e "$flag" ]]; then reason=timed-out
        elif ! [[ "$counts" =~ ^compared=[0-9]+\ unrecorded=[0-9]+\ no_comparison=[0-9]+$ ]]; then reason=failed; fi
    fi
    if [[ -n "$reason" ]]; then
        _rtb_decide_shadow_skip_log "$log" "$reason" "$(( $(_rtb_decide_shadow_ms) - start ))"
        counts="compared=0 unrecorded=0 no_comparison=${#TESTS[@]}"
    fi
    printf 'run-tests-baseline: decide shadow: %s log=%s\n' "$counts" "$log" >&2
    own=("$cap.native" "$inp" "$map" "$tfc" "$out" "$flag")
    if [[ "$RTB_DECIDE_SHADOW_CAPTURE_FROM_ENV" != 1 ]]; then own+=("$cap"); fi
    if [[ "$RTB_DECIDE_SHADOW_CAPTURE_FROM_ENV" != 1 || "$cap" != "${pfx}.decide-shadow-capture.tsv" ]]; then
        own+=("${pfx}.decide-shadow-capture.tsv")
    fi
    rm -f "${own[@]}" 2>/dev/null
    return 0
}
