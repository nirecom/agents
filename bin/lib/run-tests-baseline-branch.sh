#!/usr/bin/env bash
# Branch-side solo re-run for bin/run-tests-baseline (#2688). Source-only; needs the ledger,
# timeout and exec libs sourced first. Each failing test runs alone in this checkout before
# any base work: a pass after exit 124 is flaky-timeout-on-branch, a pass after any other exit
# is passes-alone-on-branch, and a solo failure or an inconclusive run goes on to the base.
# Results are cached by input_version (the cwd's content key; none resolves -> no cache) at
#   $(run_all_cache_dir)/branch.v1.<host>-<epoch>-<pid>.seg
# with lines `b1\t<input_version>\t<host>\t<rel-path>\t<result>\t<epoch>`; a line of any other
# shape is never trusted, so a broken or older segment falls back to a re-run.

RTB_BRANCH_PREFIX="branch.v1"
RTB_BRANCH_TAG="b1"
RTB_BRANCH_RESULTS_RE='^(pass-after-124|pass-after-other|fails-alone|inconclusive)$'
# Seconds of the shared budget the branch stage leaves for the base stage, so a test that
# never settles on the branch (always timing out, never cached) cannot starve the base runs.
RTB_BRANCH_BASE_RESERVE=150
RTB_BRANCH_SEG=""
RTB_BRANCH_RESULT=""

rtb_branch_dir() {
    run_all_cache_dir
}

rtb_branch_valid_iv() {
    [[ -n "${1:-}" && "${#1}" -le 200 && "$1" =~ ^[A-Za-z0-9:._/+=-]+$ ]]
}

# rtb_branch_input_version <root> <evidence-cli> <sid> — prints the key, or nothing.
rtb_branch_input_version() {
    local iv
    iv="$(cd "$1" 2>/dev/null && node "$(rtb_wt_native "$2")" input-version --session "$3" 2>/dev/null)" || return 0
    rtb_branch_valid_iv "$iv" && printf '%s' "$iv"
    return 0
}

# rtb_branch_cache_get <iv> <rel> — RTB_BRANCH_RESULT = the newest cached result, or "".
rtb_branch_cache_get() {
    local iv="${1:-}" rel="${2:-}" dir f
    local -a segs=()
    RTB_BRANCH_RESULT=""
    rtb_branch_valid_iv "$iv" && rtb_ledger_valid_path "$rel" || return 0
    dir="$(rtb_branch_dir)"
    for f in "$dir/$RTB_BRANCH_PREFIX".*.seg; do
        [[ -f "$f" ]] && segs+=("$f")
        [[ "${#segs[@]}" -lt "$RTB_LEDGER_MAX_SEGMENTS_READ" ]] || break
    done
    [[ "${#segs[@]}" -gt 0 ]] || return 0
    # REL travels through the environment: awk -v would interpret backslash escapes in it.
    RTB_BRANCH_RESULT="$(RTB_AWK_REL="$rel" LC_ALL=C awk -F '\t' -v TAG="$RTB_BRANCH_TAG" -v IV="$iv" -v HOST="$RUN_ALL_DUR_HOST_TOKEN" \
        -v RES="$RTB_BRANCH_RESULTS_RE" -v MAXLEN="$RTB_LEDGER_MAX_LINE_BYTES" '
        BEGIN { REL = ENVIRON["RTB_AWK_REL"] }
        length($0) <= MAXLEN && NF == 6 && $1 == TAG && $2 == IV && $3 == HOST && $4 == REL \
            && $5 ~ RES && $6 ~ /^[0-9]+$/ { print $6 "\t" $5 }' "${segs[@]}" 2>/dev/null \
        | sort -t "$(printf '\t')" -k1,1n | tail -n 1 | cut -f2)"
    return 0
}

# rtb_branch_cache_put <iv> <rel> <result> — a write failure only warns (the cache is a cache).
rtb_branch_cache_put() {
    local iv="${1:-}" rel="${2:-}" res="${3:-}" dir
    rtb_branch_valid_iv "$iv" && rtb_ledger_valid_path "$rel" && [[ "$res" =~ $RTB_BRANCH_RESULTS_RE ]] || return 0
    if [[ -z "$RTB_BRANCH_SEG" ]]; then
        dir="$(rtb_branch_dir)"
        mkdir -p "$dir" 2>/dev/null || { rtb_ledger_warn "cannot create $dir; branch results not cached"; RTB_BRANCH_SEG="-"; return 0; }
        find "$dir" -maxdepth 1 -type f -name "$RTB_BRANCH_PREFIX.*.seg" \
            -mmin +$((RTB_LEDGER_RETENTION_DAYS * 1440)) -exec rm -f {} + 2>/dev/null || true
        RTB_BRANCH_SEG="$dir/$RTB_BRANCH_PREFIX.$RUN_ALL_DUR_HOST_TOKEN-$(date +%s)-$$.seg"
    fi
    [[ "$RTB_BRANCH_SEG" != "-" ]] || return 0
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$RTB_BRANCH_TAG" "$iv" "$RUN_ALL_DUR_HOST_TOKEN" "$rel" "$res" "$(date +%s)" \
        >>"$RTB_BRANCH_SEG" 2>/dev/null || rtb_ledger_warn "append to $RTB_BRANCH_SEG failed"
    return 0
}

# rtb_branch_run_one <root> <rel> <timeout> <logdir> <exit-or-empty> — RTB_BRANCH_RESULT;
# returns 1 when the result must not be cached (setup failure, timeout under a budget slice).
rtb_branch_run_one() {
    RTB_BRANCH_RESULT="inconclusive"
    rtb_exec_one "$1" "$2" "$3" "$4" || return 1
    [[ "$RTB_EXEC_TIMEDOUT" != "1" ]] || return 1
    [[ "$RTB_EXEC_UNSUPPORTED$RTB_EXEC_DECOY$RTB_EXEC_UNRUNNABLE" == "000" ]] || return 0
    local verdict
    if [[ -n "$RTB_EXEC_STATE" ]]; then
        case "$RTB_EXEC_STATE:$RTB_EXEC_RC" in
            PASS:*) verdict=pass ;;
            FAIL:137|FAIL:143) verdict="" ;;
            FAIL:*) verdict=fail ;;
            *) verdict="" ;;
        esac
    else
        case "$RTB_EXEC_RC" in
            0) verdict=pass ;;
            77|124|137|142|143) verdict="" ;;
            *) verdict=fail ;;
        esac
    fi
    case "$verdict" in
        pass) if [[ "${5:-}" == "124" ]]; then RTB_BRANCH_RESULT="pass-after-124"; else RTB_BRANCH_RESULT="pass-after-other"; fi ;;
        fail) RTB_BRANCH_RESULT="fails-alone" ;;
    esac
    return 0
}

# rtb_branch_stage — fills CLS/DET for the tests that pass alone. Reads the caller's TESTS,
# BR_EXIT (path -> recorded exit), ROOT, SID, RTB_EVIDENCE, LOGDIR, PTT_EXPLICIT,
# PER_TEST_TIMEOUT and RTB_TIMEOUT_LEDGER; a zero budget slice leaves the test to later stages.
# shellcheck disable=SC2034  # CLS/DET are the caller's arrays
rtb_branch_stage() {
    local i t iv code res order
    iv="$(rtb_branch_input_version "$ROOT" "$RTB_EVIDENCE" "$SID")"
    # Shortest measured first (unmeasured last): one slow test that spends the whole budget
    # slice must not starve the quick ones, whose result is cached once it settles.
    order="$(for i in "${!TESTS[@]}"; do printf '%s\t%s\n' "${RTB_TIMEOUT_LEDGER[$i]:-999999999}" "$i"; done | sort -n -k1,1 -k2,2n | cut -f2)"
    for i in $order; do
        t="${TESTS[$i]}"
        code="${BR_EXIT[$t]:-}"
        rtb_branch_cache_get "$iv" "$t"
        res="$RTB_BRANCH_RESULT"
        if [[ -z "$res" ]]; then
            if [[ "$PTT_EXPLICIT" == 1 ]]; then
                rtb_timeout_budget_into "$PER_TEST_TIMEOUT" "$((SECONDS + RTB_BRANCH_BASE_RESERVE))"
            else
                rtb_timeout_slice_into "${RTB_TIMEOUT_LEDGER[$i]:-}" "$((SECONDS + RTB_BRANCH_BASE_RESERVE))"
            fi
            [[ "$RTB_TIMEOUT_SLICE_OUT" -gt 0 ]] || continue
            printf 'run-tests-baseline: branch re-run: %s %ss\n' "$t" "$RTB_TIMEOUT_SLICE_OUT" >&2
            if rtb_branch_run_one "$ROOT" "$t" "$RTB_TIMEOUT_SLICE_OUT" "$LOGDIR-branch" "$code"; then
                rtb_branch_cache_put "$iv" "$t" "$RTB_BRANCH_RESULT"
            fi
            res="$RTB_BRANCH_RESULT"
        fi
        case "$res" in
            pass-after-*)
                if [[ "$code" == "124" ]]; then
                    CLS[i]="flaky-timeout-on-branch"; DET[i]="exit-124-then-pass"
                else
                    CLS[i]="passes-alone-on-branch"; DET[i]="exit-${code:-unknown}-then-pass"
                fi ;;
        esac
    done
    [[ ! -d "$LOGDIR-branch" ]] || printf 'run-tests-baseline: branch-run logs: %s\n' "$LOGDIR-branch" >&2
    return 0
}
