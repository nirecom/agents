#!/usr/bin/env bash
# tests/tests/feature-1832-run-all-parallel/g2-calibrator-errors.sh
# Tests: bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, calibrator, error-matrix, injection, idempotency, TL2, scope:issue-specific
# Serial: drives the calibrator, which the sibling g-calibrator.sh also drives
# WHY (CPR-WPH): the calibrator is the SOLE record writer, so every rejection row asserts 4
# invariants: rejects cleanly (not skip/timeout), no RUN_CONTRACT: shape leaks, no injection
# side effect, and the pre-existing record survives byte-for-byte. An empty or missing suite
# is now "inconclusive" (exit 5 + a fixed token, #2079 S4), not a die.
# TL3 gap: a real filesystem crash mid-write (power loss, ENOSPC) is not covered here.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/_cal-fixture.sh"
REAL_RUN_ALL="${HOME:-/nonexistent}/.claude/run-all"
REAL_PRE=0; [ -e "$REAL_RUN_ALL" ] && REAL_PRE=1
cf_init
# #2687: pin the logical CPU count (it bounds --jobs-list); case_cpu_bound re-pins per row.
CF_PATH_PREFIX="$(cf_cpu_shim 16)"

CAL_TGT="bin/calibrate-test-parallelism.sh"
SENTINEL="$CF_T/INJECTED"
GOLDEN="$CF_T/golden.conf"
# A destination whose parent is a regular file — portable "unwritable" without chmod.
BLOCKED="$CF_T/blocked"; printf 'not a directory\n' > "$BLOCKED"

# 8 in-band ledger candidates in a 2-level corpus: "1 2" with --sample 4 never probes.
SX="$(cf_new_suite)"; RX="$(cf_new_real)"
cf_populate "$SX" "$RX" bin/a 4 6
cf_populate "$SX" "$RX" hooks/b 4 6
SEMPTY="$(cf_new_suite)"
FAIL_STUB="$CF_T/measure-fail"; mkdir -p "$FAIL_STUB"
printf '#!/usr/bin/env bash\necho "sample failed" >&2\nexit 3\n' > "$FAIL_STUB/measure.sh"

write_golden() {
    printf '%s\n' schema=3 host_id=fixture-host os=Linux/6.8.0 max_jobs_per_host=7 \
        measured_at=2024-01-01T00:00:00Z sample_size=4 repeat=3 logical_cpu_count=16 \
        max_width_measured=8 width_limit=jobs-list > "$RX/parallelism.conf"
    cp "$RX/parallelism.conf" "$GOLDEN"
}
contract_count() {
    printf '%s\n' "$1" | grep -cE '^[[:space:]]*RUN_CONTRACT: PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+ EXECUTED=[0-9]+' || true
}
conf_value() { sed -n "s/^$1=//p" "$RX/parallelism.conf" 2>/dev/null | head -n 1; }
conf_keys() { sed -n 's/^\([a-z_]*\)=.*/\1/p' "$RX/parallelism.conf" 2>/dev/null | LC_ALL=C sort | tr '\n' ' '; }
verdict() { case "$1" in 0|77|124) printf 'rc=%s' "$1" ;; *) printf 'reject' ;; esac; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
cal_missing() { [ -f "$CF_CAL" ] && return 1; fail "$1" "implementation missing: $CAL_TGT"; return 0; }
# inconclusive_token — the last `calibrate: inconclusive: <token>` token on stderr.
inconclusive_token() { printf '%s\n' "$CF_ERR" | sed -n 's/^calibrate: inconclusive: \([a-z-]*\).*/\1/p' | tail -n 1; }

S_DEF=4; J_DEF="1 2"; R_DEF=3; W_DEF=0

# 1. Rejection matrix — one row, four invariants
case_rejections() {
    local name field value skip s j r w suite real stub args inv tok
    while IFS='|' read -r name field value; do
        name="$(trim "$name")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        field="$(trim "$field")"; value="$(trim "$value")"
        if [ ! -f "$CF_CAL" ]; then
            for inv in exit-is-rejection no-contract-line no-injection-side-effect prior-record-preserved; do
                fail "g2-cal/reject/$name/$inv" "implementation missing: $CAL_TGT"
            done
            continue
        fi
        value="${value//%SENT%/$SENTINEL}"
        value="${value//%NL%/$'\n'}"
        [ "$value" = "<EMPTY>" ] && value=""
        s="$S_DEF"; j="$J_DEF"; r="$R_DEF"; w="$W_DEF"
        suite="$SX"; real="$RX"; stub="$(cf_stub "1:1000 2:500")"; : > "$stub/noseg"
        skip=""; [ "$value" = "<NONE>" ] && skip="$field"
        case "$field" in
            sample)    [ -n "$skip" ] || s="$value" ;;
            jobs-list) [ -n "$skip" ] || j="$value" ;;
            repeat)    [ -n "$skip" ] || r="$value" ;;
            warmup)    [ -n "$skip" ] || w="$value" ;;
            suite)     case "$value" in empty) suite="$SEMPTY" ;; *) suite="$CF_T/no-such-suite" ;; esac ;;
            measure)   stub="$FAIL_STUB" ;;
            cache)     real="$BLOCKED/cache" ;;
        esac
        args=()
        [ "$skip" = "sample" ]    || args+=(--sample "$s")
        [ "$skip" = "jobs-list" ] || args+=(--jobs-list "$j")
        [ "$skip" = "repeat" ]    || args+=(--repeat "$r")
        [ "$skip" = "warmup" ]    || args+=(--warmup "$w")
        [ -n "$skip" ] && args+=("--$skip")
        rm -f "$SENTINEL"
        write_golden
        CF_TIMEOUT=60 cf_run "$suite" "$real" "$stub" "${args[@]}"
        ck "g2-cal/reject/$name/exit-is-rejection" "reject" "$(verdict "$CF_RC")"
        ck "g2-cal/reject/$name/no-contract-line" "0" "$(contract_count "$CF_OUT$CF_ERR")"
        if [ -e "$SENTINEL" ]; then fail "g2-cal/reject/$name/no-injection-side-effect" "argument value was evaluated by a shell"
        else pass "g2-cal/reject/$name/no-injection-side-effect"; fi
        if cmp -s "$GOLDEN" "$RX/parallelism.conf"; then pass "g2-cal/reject/$name/prior-record-preserved"
        else fail "g2-cal/reject/$name/prior-record-preserved" "a rejected run mutated the existing record"; fi
        case "$field" in
            # S2: an empty suite has a plan with no parallel rows, so nothing reaches n
            # (too-few-candidates); a missing suite cannot produce the plan at all.
            suite)
                case "$value" in empty) tok=too-few-candidates ;; *) tok=plan-unavailable ;; esac
                ck "g2-cal/reject/$name/inconclusive-with-fixed-token" "5:$tok" "$CF_RC:$(inconclusive_token)" ;;
        esac
    done <<'TABLE'
# name                      | field     | value
sample-zero                 | sample    | 0
sample-negative             | sample    | -1
sample-nonnumeric           | sample    | abc
sample-float                | sample    | 1.5
sample-missing-value        | sample    | <NONE>
jobs-list-empty             | jobs-list | <EMPTY>
jobs-list-nonnumeric-token  | jobs-list | 1 x 4
jobs-list-zero-width        | jobs-list | 0 2
jobs-list-negative-width    | jobs-list | 1 -2
jobs-list-oversize-width    | jobs-list | 1 4096
jobs-list-missing-value     | jobs-list | <NONE>
repeat-zero                 | repeat    | 0
repeat-nonnumeric           | repeat    | abc
repeat-missing-value        | repeat    | <NONE>
warmup-negative             | warmup    | -1
warmup-nonnumeric           | warmup    | abc
warmup-missing-value        | warmup    | <NONE>
suite-empty                 | suite     | empty
suite-nonexistent           | suite     | missing
samples-fail                | measure   | fail
cache-destination-unwritable| cache     | unwritable
inject-sample-cmdsub        | sample    | $(touch %SENT%)
inject-jobs-backtick        | jobs-list | `touch %SENT%`
inject-repeat-semicolon     | repeat    | 1; touch %SENT%
inject-warmup-andand        | warmup    | 0 && touch %SENT%
inject-jobs-newline         | jobs-list | 1 2%NL%touch %SENT%
TABLE
}

# 2. Recalibration over an existing record — atomic replace, then idempotent
run_ok() {
    local st
    st="$(cf_stub "1:1000 2:500")"; : > "$st/noseg"
    CF_TIMEOUT=60 cf_run "$SX" "$RX" "$st" --sample 4 --jobs-list "1 2" --repeat 3 --warmup 0
}
case_recalibration() {
    local first
    cal_missing "g2-cal/recalibrate/replace-exit-zero" && return
    write_golden
    run_ok
    ck "g2-cal/recalibrate/replace-exit-zero" "0" "$CF_RC"
    # width 1 = 1000 ms, width 2 = 500 ms: the knee is 2 — never the stale 7.
    ck "g2-cal/recalibrate/selected-is-the-knee" "2" "$(cf_selected)"
    if cmp -s "$GOLDEN" "$RX/parallelism.conf"; then fail "g2-cal/recalibrate/record-replaced" "the stale record survived"
    else pass "g2-cal/recalibrate/record-replaced"; fi
    ck "g2-cal/recalibrate/no-temp-file-left-behind" "0:durations parallelism.conf " "$CF_RC:$(ls -A "$RX" 2>/dev/null | tr '\n' ' ')"
    first="$(cf_selected)"
    run_ok
    ck "g2-cal/recalibrate/rerun-exit-zero" "0" "$CF_RC"
    ck "g2-cal/recalibrate/rerun-selects-the-same-value" "$first" "$(cf_selected)"
    ck "g2-cal/recalibrate/rerun-no-temp-file-left-behind" "0:durations parallelism.conf " "$CF_RC:$(ls -A "$RX" 2>/dev/null | tr '\n' ' ')"
}

# 3. record_*: v3 key set; v1 and legacy v2 records are replaced by v3 (#2079 S11, #2687)
V3_KEYS="host_id logical_cpu_count max_jobs_per_host max_width_measured measured_at os repeat sample_size schema width_limit "
record_v3_replaces_older() {
    cal_missing "g2-cal/record/v1-replaced-exit-zero" && return
    printf '%s\n' schema=1 host_id=fixture-host count_bucket=2 jobs=7 \
        measured_at=2024-01-01T00:00:00Z sample_size=4 repeat=3 > "$RX/parallelism.conf"
    run_ok
    ck "g2-cal/record/v1-replaced-exit-zero" "0" "$CF_RC"
    ck "g2-cal/record/v1-replaced-by-v3-keys" "$V3_KEYS" "$(conf_keys)"
    ck "g2-cal/record/v1-replaced-schema-3" "3" "$(conf_value schema)"
    ck "g2-cal/record/v1-replaced-max-jobs-per-host" "2" "$(conf_value max_jobs_per_host)"
    printf '%s\n' schema=2 host_id=fixture-host os=Linux/6.8.0 max_jobs_per_host=7 \
        measured_at=2024-01-01T00:00:00Z sample_size=4 repeat=3 > "$RX/parallelism.conf"
    run_ok
    ck "g2-cal/record/legacy-v2-replaced-by-v3-keys" "$V3_KEYS" "$(conf_keys)"
    ck "g2-cal/record/legacy-v2-replaced-schema-3" "3" "$(conf_value schema)"
    write_golden
    run_ok
    ck "g2-cal/record/v3-rerun-keeps-the-key-set" "$V3_KEYS" "$(conf_keys)"
    ck "g2-cal/record/v3-rerun-same-value" "2" "$(conf_value max_jobs_per_host)"
}

# 3b. #2687 CPU4: an explicit --jobs-list wider than the logical CPU count is a usage error
# (exit 2) before any measurement; an unknown CPU count never rejects on that ground.
case_cpu_bound() {
    local name cpu jobs want st
    cal_missing "g2-cal/cpu-bound/over-count/exit" && return
    while IFS='|' read -r name cpu jobs want; do
        name="$(trim "$name")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        cpu="$(trim "$cpu")"; jobs="$(trim "$jobs")"; want="$(trim "$want")"
        write_golden
        st="$(cf_stub "1:1000 2:500 4:400 8:300")"; : > "$st/noseg"
        # --sample = the widest width, so the only usage error left to fire is the CPU bound.
        CF_PATH_PREFIX="$(cf_cpu_shim "$cpu")" CF_TIMEOUT=60 cf_run "$SX" "$RX" "$st" \
            --sample "${jobs##* }" --jobs-list "$jobs" --repeat 3 --warmup 0
        case "$want" in
            2)
                ck "g2-cal/cpu-bound/$name/exit" "2" "$CF_RC"
                ck "g2-cal/cpu-bound/$name/no-seam-call" "0" "$(cf_calls "$st")"
                if cmp -s "$GOLDEN" "$RX/parallelism.conf"; then pass "g2-cal/cpu-bound/$name/prior-record-preserved"
                else fail "g2-cal/cpu-bound/$name/prior-record-preserved" "a rejected run mutated the record"; fi ;;
            not2)
                if [ "$CF_RC" != "2" ]; then pass "g2-cal/cpu-bound/$name/exit"
                else fail "g2-cal/cpu-bound/$name/exit" "rejected with exit 2: $(printf '%s' "$CF_ERR" | head -n 1)"; fi ;;
        esac
    done <<'TABLE'
# name               | logical CPU count | --jobs-list | want
over-count           | 4                 | 1 8         | 2
over-count-by-one    | 4                 | 1 5         | 2
equal-to-count       | 4                 | 1 4         | not2
plan-cpu4-example    | 20                | 4 32        | 2
unknown-count        | unknown           | 1 8         | not2
TABLE
}

# 4. The developer's real cache dir was never touched
case_real_home_untouched() {
    local now=0; [ -e "$REAL_RUN_ALL" ] && now=1
    ck "g2-cal/isolation/real-home-run-all-untouched" "$REAL_PRE" "$now"
}

case_rejections
case_recalibration
record_v3_replaces_older
case_cpu_bound
case_real_home_untouched

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
