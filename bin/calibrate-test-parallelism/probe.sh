#!/usr/bin/env bash
# bin/calibrate-test-parallelism/probe.sh — measure unrecorded tests only when the ledger
# falls short (SOURCE ONLY; #2079 S2). Results live in memory for this run only.

PROBED=0

# cal_probe — up to 8 x shortfall unrecorded parallel tests by an even stride, MIN_W at a
# time at width MIN_W with deadline hi + 2; a test joins the candidates when its recorded
# seconds fall in the band. Stops at REQUIRED candidates or when the targets run out.
cal_probe() {
    local -a targets=() pick=() batch=()
    local short=$((REQUIRED - ${#CAND_PATH[@]})) t take i p s dl=$((BAND_HI + 2)) round=0
    local list="$CAL_WORK/probe.list" report="$CAL_WORK/probe.report"
    [ "$short" -gt 0 ] || return 0
    for ((i = 0; i < ${#POP_PATH[@]}; i++)); do
        [ -z "${POP_SECS[$i]}" ] && targets+=("${POP_PATH[$i]}")
    done
    t="${#targets[@]}"
    [ "$t" -gt 0 ] || return 0
    take=$((8 * short)); [ "$take" -le "$t" ] || take="$t"
    for ((i = 0; i < take; i++)); do pick+=("${targets[$((i * t / take))]}"); done
    i=0
    while [ "$i" -lt "$take" ] && [ "${#CAND_PATH[@]}" -lt "$REQUIRED" ]; do
        batch=("${pick[@]:$i:$MIN_W}")
        i=$((i + ${#batch[@]}))
        printf '%s\n' "${batch[@]}" > "$list"
        cal_time_check "$dl"
        cal_measure_call "$MIN_W" "$list" "$dl" probe "$report" ||
            cal_inconclusive run-failed "could not start the probe run"
        cal_check_report probe "$MIN_W" "$report" "$list"
        PROBED=$((PROBED + ${#batch[@]}))
        round=$((round + 1))
        for p in "${batch[@]}"; do
            s="${CR_REC[$p]:-}"
            [ -n "$s" ] && [ "$s" -ge "$BAND_LO" ] && [ "$s" -le "$BAND_HI" ] || continue
            CAND_PATH+=("$p"); CAND_SECS+=("$s")
        done
        printf 'calibrate: probe round %s: probed %s tests, candidates %s of %s required\n' \
            "$round" "$PROBED" "${#CAND_PATH[@]}" "$REQUIRED" >&2
    done
    return 0
}
