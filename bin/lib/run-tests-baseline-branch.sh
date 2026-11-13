#!/usr/bin/env bash
# Branch-side solo re-run for bin/run-tests-baseline (#2688, #2956 S6-S8 table 2). Source-only;
# needs the ledger, timeout and exec libs sourced first. Each failing test runs alone in this
# checkout before any base work; it is the only source of the branch-side failure lines.
# Results are cached by input_version (the cwd's content key; none resolves -> no cache) at
#   $(run_all_cache_dir)/branch.v2.<host>-<epoch>-<pid>.seg
# with lines `b2\t<input_version>\t<host>\t<rel-path>\t<result>\t<fp|->\t<epoch>`; <fp> names the
# ledger row file of the branch lines. A line of any other shape is never trusted (re-run).

RTB_BRANCH_PREFIX="branch.v2"
RTB_BRANCH_TAG="b2"
RTB_BRANCH_RESULTS_RE='^(pass-after-124|pass-after-other|fails-alone|inconclusive:(skip|rc-124|rc-142|kill-137|kill-143|unsupported|decoy|unrunnable))$'
# Results whose branch lines the base comparison reads: a cache hit needs their row file.
RTB_BRANCH_LINES_RE='^(fails-alone|inconclusive:rc-124|inconclusive:rc-142)$'
# Seconds of the shared budget the branch stage leaves for the base stage, so a test that
# never settles on the branch (always timing out, never cached) cannot starve the base runs.
RTB_BRANCH_BASE_RESERVE=150
RTB_BRANCH_SEG=""
RTB_BRANCH_RESULT=""
RTB_BRANCH_FP=""
RTB_BRANCH_RES=""

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

# rtb_branch_cache_get <iv> <rel> — RTB_BRANCH_RESULT / RTB_BRANCH_FP = the newest cached row, or "".
rtb_branch_cache_get() {
    local iv="${1:-}" rel="${2:-}" dir f row
    local -a segs=()
    RTB_BRANCH_RESULT="" RTB_BRANCH_FP=""
    rtb_branch_valid_iv "$iv" && rtb_ledger_valid_path "$rel" || return 0
    dir="$(rtb_branch_dir)"
    for f in "$dir/$RTB_BRANCH_PREFIX".*.seg; do
        [[ -f "$f" ]] && segs+=("$f")
        [[ "${#segs[@]}" -lt "$RTB_LEDGER_MAX_SEGMENTS_READ" ]] || break
    done
    [[ "${#segs[@]}" -gt 0 ]] || return 0
    # REL travels through the environment: awk -v would interpret backslash escapes in it.
    row="$(RTB_AWK_REL="$rel" LC_ALL=C awk -F '\t' -v TAG="$RTB_BRANCH_TAG" -v IV="$iv" -v HOST="$RUN_ALL_DUR_HOST_TOKEN" \
        -v RES="$RTB_BRANCH_RESULTS_RE" -v MAXLEN="$RTB_LEDGER_MAX_LINE_BYTES" '
        BEGIN { REL = ENVIRON["RTB_AWK_REL"] }
        length($0) <= MAXLEN && NF == 7 && $1 == TAG && $2 == IV && $3 == HOST && $4 == REL \
            && $5 ~ RES && ($6 == "-" || $6 ~ /^[0-9a-f]+$/ && length($6) == 64) && $7 ~ /^[0-9]+$/ \
            { print $7 "\t" $5 "\t" $6 }' "${segs[@]}" 2>/dev/null \
        | sort -t "$(printf '\t')" -k1,1n | tail -n 1)"
    [[ -n "$row" ]] || return 0
    row="${row#*$'\t'}"
    RTB_BRANCH_RESULT="${row%%$'\t'*}"
    RTB_BRANCH_FP="${row#*$'\t'}"
    return 0
}

# rtb_branch_cache_put <iv> <rel> <result> [<fp>] — a write failure only warns (the cache is a cache).
rtb_branch_cache_put() {
    local iv="${1:-}" rel="${2:-}" res="${3:-}" fp="${4:--}" dir
    rtb_branch_valid_iv "$iv" && rtb_ledger_valid_path "$rel" && [[ "$res" =~ $RTB_BRANCH_RESULTS_RE ]] || return 0
    [[ "$fp" == "-" ]] || rtb_ledger_valid_fp "$fp" || fp="-"
    if [[ -z "$RTB_BRANCH_SEG" ]]; then
        dir="$(rtb_branch_dir)"
        mkdir -p "$dir" 2>/dev/null || { rtb_ledger_warn "cannot create $dir; branch results not cached"; RTB_BRANCH_SEG="-"; return 0; }
        find "$dir" -maxdepth 1 -type f -name "branch.*.seg" \
            -mmin +$((RTB_LEDGER_RETENTION_DAYS * 1440)) -exec rm -f {} + 2>/dev/null || true
        RTB_BRANCH_SEG="$dir/$RTB_BRANCH_PREFIX.$RUN_ALL_DUR_HOST_TOKEN-$(date +%s)-$$.seg"
    fi
    [[ "$RTB_BRANCH_SEG" != "-" ]] || return 0
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$RTB_BRANCH_TAG" "$iv" "$RUN_ALL_DUR_HOST_TOKEN" "$rel" "$res" "$fp" "$(date +%s)" \
        >>"$RTB_BRANCH_SEG" 2>/dev/null || rtb_ledger_warn "append to $RTB_BRANCH_SEG failed"
    return 0
}

# rtb_branch_guard_only_fail <err> — 0 when the failed run's only hits are command guard hits the
# launcher claimed for it (bin/lib/run-all-hits.sh lines): as in tests/run-all.sh (#2669) the hit is
# that test's own FAIL, and its records stay the branch side. A root decoy hit (the test ran
# against a decoy tree) or a worktree change leaves no records the base can be set against.
rtb_branch_guard_only_fail() {
    [[ "$RTB_EXEC_STATE" == "FAIL" && -f "$1" ]] || return 1
    grep -q '^\[run-all\] command guard hit: ' "$1" 2>/dev/null || return 1
    ! grep -qE '^\[run-all\] (root decoy hit|worktree change:|[0-9]+ (root decoy hit|worktree change|command guard hit))' "$1" 2>/dev/null
}

# rtb_branch_run_one <root> <rel> <timeout> <logdir> <exit-or-empty> — RTB_BRANCH_RESULT and
# RTB_BRANCH_RES (the run's result dir); returns 1 when the result must not be cached:
# 2 = setup failure, 1 = outer timeout (the run was cut from outside, its records are not used).
rtb_branch_run_one() {
    local verdict
    RTB_BRANCH_RESULT="" RTB_BRANCH_RES=""
    rtb_exec_one "$1" "$2" "$3" "$4" || return 2
    RTB_BRANCH_RES="$4/$RTB_EXEC_SEQ.res"
    [[ "$RTB_EXEC_TIMEDOUT" != "1" ]] || return 1
    if [[ "$RTB_EXEC_UNSUPPORTED" == "1" ]]; then RTB_BRANCH_RESULT="inconclusive:unsupported"; return 0; fi
    if [[ "$RTB_EXEC_DECOY" == "1" ]] && ! rtb_branch_guard_only_fail "$4/$RTB_EXEC_SEQ.err"; then
        RTB_BRANCH_RESULT="inconclusive:decoy"; return 0
    fi
    if [[ "$RTB_EXEC_UNRUNNABLE" == "1" ]]; then RTB_BRANCH_RESULT="inconclusive:unrunnable"; return 0; fi
    if [[ -n "$RTB_EXEC_STATE" ]]; then
        case "$RTB_EXEC_STATE:$RTB_EXEC_RC" in
            PASS:*) verdict=pass ;;
            FAIL:137|FAIL:143|FAIL:124|FAIL:142) verdict="rc-$RTB_EXEC_RC" ;;
            FAIL:*) verdict=fail ;;
            *) verdict=skip ;;
        esac
    else
        case "$RTB_EXEC_RC" in
            0) verdict=pass ;;
            124|137|142|143) verdict="rc-$RTB_EXEC_RC" ;;
            77) verdict=skip ;;
            *) verdict=fail ;;
        esac
    fi
    case "$verdict" in
        pass) if [[ "${5:-}" == "124" ]]; then RTB_BRANCH_RESULT="pass-after-124"; else RTB_BRANCH_RESULT="pass-after-other"; fi ;;
        fail) RTB_BRANCH_RESULT="fails-alone" ;;
        rc-137|rc-143) RTB_BRANCH_RESULT="inconclusive:kill-${verdict#rc-}" ;;
        *) RTB_BRANCH_RESULT="inconclusive:$verdict" ;;
    esac
    return 0
}

# rtb_branch_classify <i> <result> <code> — table 2: CLS/DET for a result settled on the branch,
# else BR_END[i] for the base comparison (BR_RES[i] already set).
# shellcheck disable=SC2034  # CLS/DET/BR_END/BR_NOREC are the caller's arrays
rtb_branch_classify() {
    local i="$1" res="$2" code="$3"
    case "$res" in
        pass-after-*)
            if [[ "$code" == "124" ]]; then
                CLS[i]="flaky-timeout-on-branch"; DET[i]="exit-124-then-pass"
            else
                CLS[i]="passes-alone-on-branch"; DET[i]="exit-${code:-unknown}-then-pass"
            fi ;;
        inconclusive:kill-*) CLS[i]="undetermined"; DET[i]="ambiguous-exit-${res#inconclusive:kill-}" ;;
        # No branch records: the base still runs, so its own decoy / unrunnable row can name the
        # cause; any base verdict besides is records missing on the branch (rtb_cls_table1 / _base_pass).
        inconclusive:decoy|inconclusive:unrunnable) BR_END[i]="normal"; BR_NOREC[i]=1 ;;
        inconclusive:rc-124|inconclusive:rc-142) BR_END[i]="interrupted" ;;
        *) BR_END[i]="normal" ;;
    esac
}

# rtb_branch_stage — fills CLS/DET (table 2) or BR_RES/BR_END for each test. Reads the caller's
# TESTS, BR_EXIT (path -> recorded exit), ROOT, SID, RTB_EVIDENCE, LOGDIR, TMP_BASE, PTT_EXPLICIT,
# PER_TEST_TIMEOUT and RTB_TIMEOUT_LEDGER. A test not run (zero budget slice), cut by the outer
# timeout or not set up is undetermined: its re-run is requested (exit 8).
# shellcheck disable=SC2034  # CLS/DET/BR_RES are the caller's arrays
rtb_branch_stage() {
    local i t iv code res fp order rc bl="$LOGDIR-branch"
    iv="$(rtb_branch_input_version "$ROOT" "$RTB_EVIDENCE" "$SID")"
    # Shortest measured first (unmeasured last): one slow test that spends the whole budget
    # slice must not starve the quick ones, whose result is cached once it settles.
    order="$(for i in "${!TESTS[@]}"; do printf '%s\t%s\n' "${RTB_TIMEOUT_LEDGER[$i]:-999999999}" "$i"; done | sort -n -k1,1 -k2,2n | cut -f2)"
    for i in $order; do
        t="${TESTS[$i]}"
        code="${BR_EXIT[$t]:-}"
        rtb_branch_cache_get "$iv" "$t"
        res="$RTB_BRANCH_RESULT"
        BR_RES[i]="$bl/cache-$i.res"
        if [[ "$res" =~ $RTB_BRANCH_LINES_RE ]]; then
            # A hit whose lines cannot be read back is a miss: the branch re-runs.
            mkdir -p "$bl" 2>/dev/null
            rtb_ledger_lines_load "$RTB_BRANCH_FP" "${BR_RES[i]}" "$TMP_BASE" || res=""
        elif [[ -n "$res" ]]; then
            rm -rf "${BR_RES[i]}"; mkdir -p "${BR_RES[i]}" 2>/dev/null
        fi
        if [[ -z "$res" ]]; then
            if [[ "$PTT_EXPLICIT" == 1 ]]; then
                rtb_timeout_budget_into "$PER_TEST_TIMEOUT" "$((SECONDS + RTB_BRANCH_BASE_RESERVE))"
            else
                rtb_timeout_slice_into "${RTB_TIMEOUT_LEDGER[$i]:-}" "$((SECONDS + RTB_BRANCH_BASE_RESERVE))"
            fi
            if [[ "$RTB_TIMEOUT_SLICE_OUT" -le 0 ]]; then
                CLS[i]="undetermined"; DET[i]="budget-exhausted"; continue
            fi
            printf 'run-tests-baseline: branch re-run: %s %ss\n' "$t" "$RTB_TIMEOUT_SLICE_OUT" >&2
            rc=0
            rtb_branch_run_one "$ROOT" "$t" "$RTB_TIMEOUT_SLICE_OUT" "$bl" "$code" || rc=$?
            case "$rc" in
                1) CLS[i]="undetermined"; DET[i]="budget-exhausted"; continue ;;
                2) CLS[i]="undetermined"; DET[i]="exec-setup-failed"; continue ;;
            esac
            res="$RTB_BRANCH_RESULT" fp="-"
            if [[ "$res" =~ $RTB_BRANCH_LINES_RE ]]; then
                BR_RES[i]="$RTB_BRANCH_RES"
                fp="$(rtb_ledger_lines_store "${BR_RES[i]}" "$ROOT" "$ROOT" "$TMP_BASE")"
            else
                # skip and unsupported leave no failure lines: the branch side is "no records".
                rm -rf "${BR_RES[i]}"; mkdir -p "${BR_RES[i]}" 2>/dev/null
            fi
            rtb_branch_cache_put "$iv" "$t" "$res" "$fp"
        fi
        rtb_branch_classify "$i" "$res" "$code"
    done
    [[ ! -d "$bl" ]] || printf 'run-tests-baseline: branch-run logs: %s\n' "$bl" >&2
    return 0
}
