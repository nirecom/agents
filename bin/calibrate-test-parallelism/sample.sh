#!/usr/bin/env bash
# bin/calibrate-test-parallelism/sample.sh — population, ledger candidates, sample and
# reserve, feasibility, width narrowing (SOURCE ONLY; #2079 S2, #2687). Needs the entry
# point's globals.
_SAMPLE_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

POP_PATH=(); POP_SECS=(); PLAN_ROWS=0
CAND_PATH=(); CAND_SECS=(); LEDGER_CANDS=0
SAMPLE_P=(); SAMPLE_S=(); RESERVE_P=(); RESERVE_S=()
SAMPLE_SUM=0; SAMPLE_LONGEST=0

# cal_population — the parallel-lane rows of the runner's own plan (no scan of our own).
cal_population() {
    local out="$CAL_WORK/plan.out" line rest lane path seen=0
    [ -d "$TESTS_DIR" ] || return 1
    env "TESTS_DIR=$TESTS_DIR" TEST_LANES=off RUN_ALL_PROGRESS=off \
        bash "$RUNNER" --print-plan -j 1 --all > "$out" 2>/dev/null || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            tests_dir=*) seen=1; continue ;;
            "plan	"*) ;;
            *) continue ;;
        esac
        PLAN_ROWS=$((PLAN_ROWS + 1))
        rest="${line#plan	}"; rest="${rest#*	}"
        lane="${rest%%	*}"; rest="${rest#*	}"
        path="${rest%	*}"
        [ "$lane" = "parallel" ] && [ -n "$path" ] && POP_PATH+=("$path")
    done < "$out"
    [ "$seen" -eq 1 ]
}

# cal_ledger_secs — real-area ledger seconds per population row (read only, no writer init).
cal_ledger_secs() {
    local keys="$CAL_WORK/pop.keys" secs="$CAL_WORK/pop.secs" i id s
    POP_SECS=()
    for ((i = 0; i < ${#POP_PATH[@]}; i++)); do
        POP_SECS[i]=""
        run_all_dur_key_into "${POP_PATH[$i]}" "$_SAMPLE_SCRIPT_CHECKOUT_ROOT" || continue
        printf '%s\t%s\n' "$i" "$RUN_ALL_DUR_KEY_OUT"
    done > "$keys"
    run_all_dur_lookup "$_SAMPLE_SCRIPT_CHECKOUT_ROOT" "$keys" "$secs"
    while IFS="$(printf '\t')" read -r id s; do
        if ! is_uint "$id" || ! is_uint "$s"; then continue; fi
        [ "$id" -lt "${#POP_PATH[@]}" ] && POP_SECS[id]="$s"
    done < "$secs"
    for ((i = 0; i < ${#POP_PATH[@]}; i++)); do
        s="${POP_SECS[$i]}"
        [ -n "$s" ] && [ "$s" -ge "$BAND_LO" ] && [ "$s" -le "$BAND_HI" ] || continue
        CAND_PATH+=("${POP_PATH[$i]}"); CAND_SECS+=("$s")
    done
    LEDGER_CANDS="${#CAND_PATH[@]}"
}

# cal_select — n by an even stride over the candidate order; the rest, in order, is the reserve.
cal_select() {
    local c="${#CAND_PATH[@]}" i j
    local -A taken=()
    SAMPLE_P=(); SAMPLE_S=(); RESERVE_P=(); RESERVE_S=()
    # shellcheck disable=SC2153  # SAMPLE_N is the entry point's validated --sample
    for ((i = 0; i < SAMPLE_N; i++)); do
        j=$((i * c / SAMPLE_N))
        taken[$j]=1
        SAMPLE_P+=("${CAND_PATH[$j]}"); SAMPLE_S+=("${CAND_SECS[$j]}")
    done
    for ((j = 0; j < c; j++)); do
        [ -n "${taken[$j]:-}" ] && continue
        RESERVE_P+=("${CAND_PATH[$j]}"); RESERVE_S+=("${CAND_SECS[$j]}")
    done
}

# cal_size_sample — MIN_W, MAX_W, SAMPLE_N (3 x the widest width unless --sample) and
# REQUIRED (sample + a quarter reserve) from the current WIDTHS.
cal_size_sample() {
    MIN_W="${WIDTHS[0]}"; MAX_W="${WIDTHS[$((${#WIDTHS[@]} - 1))]}"
    if [ -n "$SAMPLE" ]; then SAMPLE_N="$SAMPLE"; else SAMPLE_N=$((3 * MAX_W)); fi
    REQUIRED=$((SAMPLE_N + (SAMPLE_N + 3) / 4))
}

# cal_sample_sums — SAMPLE_SUM and SAMPLE_LONGEST of the selected sample's ledger seconds.
cal_sample_sums() {
    local s
    SAMPLE_SUM=0; SAMPLE_LONGEST=0
    for s in "${SAMPLE_S[@]}"; do
        SAMPLE_SUM=$((SAMPLE_SUM + s))
        [ "$s" -gt "$SAMPLE_LONGEST" ] && SAMPLE_LONGEST="$s"
    done
    return 0
}

# cal_feasible — selection-time seconds: sum >= longest x max width, or nothing is measured.
cal_feasible() {
    cal_sample_sums
    if [ "$SAMPLE_SUM" -lt $((SAMPLE_LONGEST * MAX_W)) ]; then
        cal_inconclusive infeasible-sample \
            "sample total ${SAMPLE_SUM}s is below longest ${SAMPLE_LONGEST}s x widest width $MAX_W; one test would dominate${CAL_NARROWED:+ ($CAL_NARROWED)}"
    fi
}

# cal_fit_widths <run|dry> — derived widths only: drop the widest width while the corpus
# cannot fill it. Rules in order: candidates >= sample size; sample sum >= longest x widest
# width; estimated total <= the time limit. "dry" judges the ledger candidates at the band
# midpoint. Sets CAL_FIT_REASON (empty = the widths fit), CAL_WIDTH_LIMIT (the last drop's
# rule) and CAL_NARROWED ("narrowed from <orig> to <widest>" when any width was dropped).
CAL_FIT_REASON=""; CAL_WIDTH_LIMIT=""; CAL_NARROWED=""
cal_fit_widths() {
    local orig="$MAX_W" mid=$(( (BAND_LO + BAND_HI + 1) / 2 )) cands sum longest
    CAL_FIT_REASON=""
    [ "$WIDTH_SOURCE" = "derived" ] || return 0
    while :; do
        CAL_FIT_REASON=""
        if [ "$1" = "dry" ]; then cands="$LEDGER_CANDS"; else cands="${#CAND_PATH[@]}"; fi
        if [ "$cands" -lt "$SAMPLE_N" ]; then
            CAL_FIT_REASON="candidates"
        else
            if [ "$1" = "dry" ]; then
                sum=$((SAMPLE_N * mid)); longest="$mid"
            else
                cal_select; cal_sample_sums; sum="$SAMPLE_SUM"; longest="$SAMPLE_LONGEST"
            fi
            if [ "$sum" -lt $((longest * MAX_W)) ]; then
                CAL_FIT_REASON="sample"
            else
                cal_estimate "$sum" "$longest"
                [ "$CAL_TOTAL_S" -le $((TIME_LIMIT * 60)) ] || CAL_FIT_REASON="time-limit"
            fi
        fi
        [ -n "$CAL_FIT_REASON" ] && [ "${#WIDTHS[@]}" -gt 1 ] || break
        WIDTHS=("${WIDTHS[@]:0:$((${#WIDTHS[@]} - 1))}")
        CAL_WIDTH_LIMIT="$CAL_FIT_REASON"
        cal_size_sample
    done
    [ "$MAX_W" = "$orig" ] || CAL_NARROWED="narrowed from $orig to $MAX_W"
    if [ -z "$CAL_FIT_REASON" ] && [ -n "$CAL_NARROWED" ]; then
        printf 'calibrate: widths %s (%s)\n' "$CAL_NARROWED" "$CAL_WIDTH_LIMIT" >&2
    fi
    return 0
}

# cal_predict <width> <sum> <longest> — P(W) = max(ceil(sum / W), longest), into CAL_P.
cal_predict() {
    CAL_P=$(( ($2 + $1 - 1) / $1 ))
    [ "$CAL_P" -lt "$3" ] && CAL_P="$3"
    return 0
}

# cal_estimate <sum> <longest> — one ladder pass (sum of P(W)) and the whole run, in seconds.
cal_estimate() {
    local w pass=0
    for w in "${WIDTHS[@]}"; do cal_predict "$w" "$1" "$2"; pass=$((pass + CAL_P)); done
    CAL_PASS_S="$pass"
    CAL_TOTAL_S=$(( (WARMUP + REPEAT) * pass ))
}

# cal_replace_overrun — each overrun path, in place, by the reserve head; then re-check.
cal_replace_overrun() {
    local p i hit
    for p in "${CAL_OVERRUN[@]}"; do
        hit=""
        for ((i = 0; i < ${#SAMPLE_P[@]}; i++)); do
            [ "${SAMPLE_P[$i]}" = "$p" ] && { hit="$i"; break; }
        done
        [ -n "$hit" ] || continue
        [ "${#RESERVE_P[@]}" -gt 0 ] || cal_inconclusive reserve-exhausted \
            "no reserve test is left to replace $p (revision $((REVISIONS + 1)))"
        SAMPLE_P[hit]="${RESERVE_P[0]}"; SAMPLE_S[hit]="${RESERVE_S[0]}"
        RESERVE_P=("${RESERVE_P[@]:1}"); RESERVE_S=("${RESERVE_S[@]:1}")
    done
    cal_feasible
}

# cal_dry_run — the plan and an approximate cost; nothing is run or written. The probe is
# planned for the full widths (the real run probes before narrowing), then the widths are
# narrowed by the same rules; estimate_total_s = probe rounds + ladder total, in seconds.
cal_dry_run() {
    local short=$((REQUIRED - LEDGER_CANDS)) targets=0 maxp i mid rounds probe_w="$MIN_W"
    [ "$short" -ge 0 ] || short=0
    for ((i = 0; i < ${#POP_PATH[@]}; i++)); do [ -z "${POP_SECS[$i]}" ] && targets=$((targets + 1)); done
    maxp=$((8 * short)); [ "$maxp" -le "$targets" ] || maxp="$targets"
    rounds=$(( (maxp + probe_w - 1) / probe_w ))
    mid=$(( (BAND_LO + BAND_HI + 1) / 2 ))
    cal_fit_widths dry
    cal_estimate $((SAMPLE_N * mid)) "$mid"
    printf 'plan: widths %s; sample %s tests; required %s (sample + reserve)\n' "${WIDTHS[*]}" "$SAMPLE_N" "$REQUIRED"
    printf 'plan: band %s:%s s; ledger candidates %s; shortfall %s\n' "$BAND_LO" "$BAND_HI" "$LEDGER_CANDS" "$short"
    if [ "$short" -gt 0 ]; then
        printf 'plan: probe up to %s of %s unrecorded tests, %s per round at width %s, deadline %ss; at most %s rounds (~%ss)\n' \
            "$maxp" "$targets" "$probe_w" "$probe_w" "$((BAND_HI + 2))" "$rounds" "$((rounds * (BAND_HI + 2)))"
    else
        printf 'plan: probe not needed\n'
    fi
    if [ -n "$CAL_FIT_REASON" ]; then
        printf 'plan: the corpus cannot fill even width %s (%s)%s\n' "$MAX_W" "$CAL_FIT_REASON" "${CAL_NARROWED:+; $CAL_NARROWED}"
    fi
    printf 'plan: estimate ~%ss per ladder pass, ~%ss in total (approximate: band midpoint %ss per test)\n' \
        "$CAL_PASS_S" "$CAL_TOTAL_S" "$mid"
    printf 'plan: estimate_total_s=%s\n' "$((rounds * (BAND_HI + 2) + CAL_TOTAL_S))"
    printf 'plan: warmup %s, repeat %s; time limit %s min\n' "$WARMUP" "$REPEAT" "$TIME_LIMIT"
    printf 'plan: nothing was measured and nothing was written\n'
}
