#!/usr/bin/env bash
# bin/calibrate-test-parallelism/measure.sh — one child run and its verdict (SOURCE ONLY).
# Needs SCRIPT_CHECKOUT_ROOT, RUNNER, bin/lib/run-all-parallelism.sh, bin/lib/run-all-durations.sh
# and TEST_LANES=off. Design: #2079 S3 ("one child run", seam, overrun, time limit).

# A report is a line file: source= rc= ms= [width=] [inflight=] segments=
# recorded=<path>\t<secs> ... unrecorded=<path> ... [seam_failed=1]

is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${#1}" -le 9 ]
}

now_ms() {
    local t s f
    t="${EPOCHREALTIME:-}"
    if [ -n "$t" ]; then
        s="${t%%[.,]*}"; f="${t#*[.,]}"
        f="${f}000"; f="${f:0:3}"
        printf '%s' "$((s * 1000 + 10#$f))"
        return 0
    fi
    t="$(date +%s 2>/dev/null)"
    is_uint "$t" || t=0
    printf '%s' "$((t * 1000))"
}

# cal_parse_start_lines <stderr-file> — pure: submitted=<path> per `start` line, each distinct
# j=<J>, then inflight_max=<K>. Verdict lines are a replay, so their seconds are never read.
cal_parse_start_lines() {
    local line rest path js inf seen=" " maxi=0
    [ -f "${1:-}" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            "[run-all] "*" start "*" (j="*" inflight="*")") ;;
            *) continue ;;
        esac
        rest="${line#"[run-all] "}"
        case "${rest%% *}" in ''|*[!0-9/]*) continue ;; esac
        rest="${rest#* start }"
        path="${rest% (j=*}"
        js="${rest##* (j=}"
        inf="${js##* inflight=}"; inf="${inf%)}"
        js="${js%% *}"
        printf 'submitted=%s\n' "$path"
        case "$seen" in *" $js "*) ;; *) seen="$seen$js "; printf 'j=%s\n' "$js" ;; esac
        if is_uint "$inf" && [ "$inf" -gt "$maxi" ]; then maxi="$inf"; fi
    done < "$1"
    printf 'inflight_max=%s\n' "$maxi"
}

# cal_new_rundir — a fresh throwaway cache area for ONE child run.
cal_new_rundir() {
    if [ -n "${CAL_WORK:-}" ]; then mktemp -d "$CAL_WORK/run.XXXXXX"; else mktemp -d; fi
}

# cal_report_records <rundir> <list> — segments= and recorded= lines from the throwaway
# ledger. The lookup runs in a subshell so the caller's RUN_ALL_CACHE_DIR never moves.
cal_report_records() {
    local dir="$1" list="$2"
    (
        RUN_ALL_CACHE_DIR="$dir"; export RUN_ALL_CACHE_DIR
        local -a paths=()
        local p i id secs
        while IFS= read -r p || [ -n "$p" ]; do
            p="${p%$'\r'}"; [ -n "$p" ] && paths+=("$p")
        done < "$list"
        for ((i = 0; i < ${#paths[@]}; i++)); do
            run_all_dur_key_into "${paths[$i]}" "$SCRIPT_CHECKOUT_ROOT" || continue
            printf '%s\t%s\n' "$i" "$RUN_ALL_DUR_KEY_OUT"
        done > "$dir.keys"
        run_all_dur_lookup "$SCRIPT_CHECKOUT_ROOT" "$dir.keys" "$dir.secs"
        printf 'segments=%s\n' "$RUN_ALL_DUR_SEGMENTS_READ"
        while IFS="$(printf '\t')" read -r id secs; do
            if ! is_uint "$id" || ! is_uint "$secs"; then continue; fi
            printf 'recorded=%s\t%s\n' "${paths[$id]}" "$secs"
        done < "$dir.secs"
        rm -f "$dir.keys" "$dir.secs"
    )
}

# cal_child_run <width> <list> <deadline> <phase> <report> — the real runner, once.
cal_child_run() {
    local w="$1" list="$2" dl="$3" report="$5" dir err parsed t0 t1 rc=0 p js="" n=0 key
    local -a paths=()
    local -A rec=()
    dir="$(cal_new_rundir)" || return 1
    err="$dir.err"; parsed="$dir.parsed"
    while IFS= read -r p || [ -n "$p" ]; do
        p="${p%$'\r'}"; [ -n "$p" ] && paths+=("$p")
    done < "$list"
    t0="$(now_ms)"
    env "RUN_ALL_CACHE_DIR=$dir" "TESTS_DIR=${TESTS_DIR:-}" TEST_LANES=off RUN_ALL_PROGRESS=on \
        bash "$RUNNER" -j "$w" --deadline "$dl" "${paths[@]}" >/dev/null 2>"$err" || rc=$?
    t1="$(now_ms)"
    cal_parse_start_lines "$err" > "$parsed" 2>/dev/null
    {
        printf 'source=runner\nrc=%s\nms=%s\n' "$rc" "$((t1 - t0))"
        while IFS= read -r p; do
            case "$p" in j=*) js="${p#j=}"; n=$((n + 1)) ;; esac
        done < "$parsed"
        # More than one distinct j= is a width the runner did not hold: report it as 0.
        [ "$n" -eq 1 ] && printf 'width=%s\n' "$js"
        [ "$n" -gt 1 ] && printf 'width=0\n'
        sed -n 's/^inflight_max=/inflight=/p' "$parsed"
        cal_report_records "$dir" "$list"
    } > "$report"
    while IFS= read -r p; do
        case "$p" in recorded=*) p="${p#recorded=}"; run_all_dur_key_into "${p%	*}" "$SCRIPT_CHECKOUT_ROOT" && rec["$RUN_ALL_DUR_KEY_OUT"]=1 ;; esac
    done < "$report"
    while IFS= read -r p; do
        case "$p" in submitted=*) ;; *) continue ;; esac
        p="${p#submitted=}"
        run_all_dur_key_into "$p" "$SCRIPT_CHECKOUT_ROOT" || continue
        key="$RUN_ALL_DUR_KEY_OUT"
        [ -n "${rec[$key]:-}" ] || printf 'unrecorded=%s\n' "$p" >> "$report"
    done < "$parsed"
    rm -rf "$dir" "$err" "$parsed"
    return 0
}

# cal_seam_run <width> <list> <deadline> <phase> <report> — RUN_ALL_CALIBRATION_MEASURE_CMD.
# Line 1 is ms; rc= / width= / unfinished= may follow (defaults: 0, as requested, none).
cal_seam_run() {
    local w="$1" list="$2" dl="$3" ph="$4" report="$5" dir raw line first=1 src=0
    dir="$(cal_new_rundir)" || return 1
    raw="$dir.raw"
    env "RUN_ALL_CACHE_DIR=$dir" bash "$MEASURE_CMD" "$w" "$list" "$dl" "$ph" > "$raw" 2>/dev/null || src=$?
    {
        printf 'source=seam\n'
        [ "$src" -eq 0 ] || printf 'seam_failed=1\n'
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            if [ "$first" -eq 1 ]; then
                first=0
                line="${line#"${line%%[![:space:]]*}"}"
                line="${line%"${line##*[![:space:]]}"}"
                printf 'ms=%s\n' "$line"
                continue
            fi
            case "$line" in
                rc=*|width=*) printf '%s\n' "$line" ;;
                unfinished=*) printf 'unrecorded=%s\n' "${line#unfinished=}" ;;
            esac
        done < "$raw"
        cal_report_records "$dir" "$list"
    } > "$report"
    rm -rf "$dir" "$raw"
    return 0
}

cal_measure_call() {
    if [ -n "${MEASURE_CMD:-}" ]; then cal_seam_run "$@"; else cal_child_run "$@"; fi
}

# cal_time_check <deadline> — stop before a child run that could cross --time-limit.
cal_time_check() {
    if [ $((SECONDS - CAL_T0 + $1)) -gt $((TIME_LIMIT * 60)) ]; then
        cal_inconclusive time-limit "elapsed $((SECONDS - CAL_T0))s + next deadline ${1}s exceeds --time-limit ${TIME_LIMIT} min"
    fi
}

# cal_read_report <report> — CR_RC CR_MS CR_WIDTH CR_INFLIGHT CR_SEGS CR_SOURCE CR_FAILED,
# CR_REC (assoc path -> secs), CR_UNREC (array).
cal_read_report() {
    local line v
    CR_RC=0; CR_MS=""; CR_WIDTH=""; CR_INFLIGHT=""; CR_SEGS=0; CR_SOURCE=""; CR_FAILED=0
    CR_REC=(); CR_UNREC=()
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            source=*) CR_SOURCE="${line#source=}" ;;
            seam_failed=*) CR_FAILED=1 ;;
            rc=*) CR_RC="${line#rc=}" ;;
            ms=*) CR_MS="${line#ms=}" ;;
            width=*) CR_WIDTH="${line#width=}" ;;
            inflight=*) CR_INFLIGHT="${line#inflight=}" ;;
            segments=*) CR_SEGS="${line#segments=}" ;;
            recorded=*) v="${line#recorded=}"; CR_REC["${v%	*}"]="${v##*	}" ;;
            unrecorded=*) CR_UNREC+=("${line#unrecorded=}") ;;
        esac
    done < "$1"
}

# cal_check_report <phase> <width> <report> <list> — dies inconclusive on a broken run;
# otherwise CAL_MS and CAL_OVERRUN (paths) for warmup/measure.
cal_check_report() {
    local ph="$1" w="$2" report="$3" list="$4" p v sum=0
    CAL_OVERRUN=()
    cal_read_report "$report"
    # shellcheck disable=SC2034  # read by the entry point's ladder
    CAL_MS="$CR_MS"
    [ "$CR_FAILED" -eq 0 ] || cal_inconclusive run-failed "the measurement command failed ($ph, width $w)"
    is_uint "$CR_MS" || cal_inconclusive run-failed "no elapsed time from the $ph run at width $w"
    case "$CR_RC" in
        0|1|3) ;;
        *) cal_inconclusive run-failed "the $ph run at width $w exited $CR_RC" ;;
    esac
    [ "$ph" = "probe" ] && return 0
    if [ -n "$CR_WIDTH" ] && [ "$CR_WIDTH" != "$w" ]; then
        cal_inconclusive width-not-honoured "requested width $w, the run reported $CR_WIDTH"
    fi
    if [ -n "$CR_INFLIGHT" ] && is_uint "$CR_INFLIGHT" && [ "$CR_INFLIGHT" -lt "$w" ]; then
        cal_inconclusive width-not-honoured "requested width $w, at most $CR_INFLIGHT tests ran at once"
    fi
    # A seam that wrote no ledger segment gives timing only; the per-test checks need records.
    if [ "$CR_SOURCE" = "seam" ] && [ "$CR_SEGS" = "0" ]; then return 0; fi
    if [ "$CR_RC" = "3" ]; then
        [ "${#CR_UNREC[@]}" -gt 0 ] || cal_inconclusive run-failed "the $ph run at width $w hit its deadline with no unfinished test identified"
        CAL_OVERRUN=("${CR_UNREC[@]}")
        return 0
    fi
    while IFS= read -r p || [ -n "$p" ]; do
        p="${p%$'\r'}"; [ -n "$p" ] || continue
        v="${CR_REC[$p]:-}"
        [ -n "$v" ] || cal_inconclusive run-failed "the $ph run at width $w completed without a record for $p"
        sum=$((sum + v))
    done < "$list"
    while IFS= read -r p || [ -n "$p" ]; do
        p="${p%$'\r'}"; [ -n "$p" ] || continue
        v="${CR_REC[$p]}"
        [ $((v * MAX_W)) -gt "$sum" ] && CAL_OVERRUN+=("$p")
    done < "$list"
    return 0
}

declare -A CR_REC=()
CR_UNREC=()
CAL_OVERRUN=()
