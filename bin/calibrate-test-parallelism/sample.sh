#!/usr/bin/env bash
# bin/calibrate-test-parallelism/sample.sh — population, ledger candidates, sample and
# reserve, feasibility (SOURCE ONLY; #2079 S2). Needs the entry point's globals.

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
        run_all_dur_key_into "${POP_PATH[$i]}" "$AGENTS_DIR" || continue
        printf '%s\t%s\n' "$i" "$RUN_ALL_DUR_KEY_OUT"
    done > "$keys"
    run_all_dur_lookup "$AGENTS_DIR" "$keys" "$secs"
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

# cal_feasible — selection-time seconds: sum >= longest x max width, or nothing is measured.
cal_feasible() {
    local s
    SAMPLE_SUM=0; SAMPLE_LONGEST=0
    for s in "${SAMPLE_S[@]}"; do
        SAMPLE_SUM=$((SAMPLE_SUM + s))
        [ "$s" -gt "$SAMPLE_LONGEST" ] && SAMPLE_LONGEST="$s"
    done
    if [ "$SAMPLE_SUM" -lt $((SAMPLE_LONGEST * MAX_W)) ]; then
        cal_inconclusive infeasible-sample \
            "sample total ${SAMPLE_SUM}s is below longest ${SAMPLE_LONGEST}s x widest width $MAX_W; one test would dominate"
    fi
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

# cal_dry_run — the plan and an approximate cost; nothing is run or written.
cal_dry_run() {
    local short=$((REQUIRED - LEDGER_CANDS)) targets=0 maxp i mid rounds
    [ "$short" -ge 0 ] || short=0
    for ((i = 0; i < ${#POP_PATH[@]}; i++)); do [ -z "${POP_SECS[$i]}" ] && targets=$((targets + 1)); done
    maxp=$((8 * short)); [ "$maxp" -le "$targets" ] || maxp="$targets"
    rounds=$(( (maxp + MIN_W - 1) / MIN_W ))
    mid=$(( (BAND_LO + BAND_HI + 1) / 2 ))
    cal_estimate $((SAMPLE_N * mid)) "$mid"
    printf 'plan: widths %s; sample %s tests; required %s (sample + reserve)\n' "${WIDTHS[*]}" "$SAMPLE_N" "$REQUIRED"
    printf 'plan: band %s:%s s; ledger candidates %s; shortfall %s\n' "$BAND_LO" "$BAND_HI" "$LEDGER_CANDS" "$short"
    if [ "$short" -gt 0 ]; then
        printf 'plan: probe up to %s of %s unrecorded tests, %s per round at width %s, deadline %ss; at most %s rounds (~%ss)\n' \
            "$maxp" "$targets" "$MIN_W" "$MIN_W" "$((BAND_HI + 2))" "$rounds" "$((rounds * (BAND_HI + 2)))"
    else
        printf 'plan: probe not needed\n'
    fi
    printf 'plan: estimate ~%ss per ladder pass, ~%ss in total (approximate: band midpoint %ss per test)\n' \
        "$CAL_PASS_S" "$CAL_TOTAL_S" "$mid"
    printf 'plan: warmup %s, repeat %s; time limit %s min\n' "$WARMUP" "$REPEAT" "$TIME_LIMIT"
    printf 'plan: nothing was measured and nothing was written\n'
}
