# Parallel case runner: run_case, run_case_sync, collect_cases
# run_case <fn> backgrounds a case (subshell, so its env never leaks); run_case_sync <fn>
# runs a static file-content case in-process. Each writes result-<seq>-<fn>.txt ending in
# an rc tag, so a case aborted by set -e is reported as FAIL, never silently lost.
# IC_TEST_JOBS caps concurrent background cases (default 4).

PASS=0
FAIL=0

# pass/fail only print; collect_cases counts the lines (cases run in subshells).
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; }

# The per-run seconds are a hang guard, not an assertion: concurrent cases on a loaded
# Windows host take ~20 s per issue-create run, so lift them to IC_TEST_RUN_TIMEOUT_FLOOR.
run_with_timeout() {
    local secs="$1" floor="${IC_TEST_RUN_TIMEOUT_FLOOR:-120}"; shift
    (( secs >= floor )) || secs="$floor"
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

IC_JOBS="${IC_TEST_JOBS:-4}"
IC_RUNNING=0
IC_SEQ=0
IC_RC_TAG="__IC_CASE_RC="

_ic_result_path() {
    IC_SEQ=$((IC_SEQ + 1))
    printf -v IC_RESULT_PATH '%s/results/result-%03d-%s.txt' "${IC_TMP_ROOT:?}" "$IC_SEQ" "$1"
}

run_case() {
    local fn="${1:?run_case requires a function name}"
    _ic_result_path "$fn"
    if (( IC_RUNNING >= IC_JOBS )); then
        wait -n || true
        IC_RUNNING=$((IC_RUNNING - 1))
    fi
    ( trap 'printf "%s%s\n" "$IC_RC_TAG" "$?"' EXIT; "$fn" ) > "$IC_RESULT_PATH" 2>&1 &
    IC_RUNNING=$((IC_RUNNING + 1))
}

run_case_sync() {
    local fn="${1:?run_case_sync requires a function name}" rc=0
    _ic_result_path "$fn"
    "$fn" > "$IC_RESULT_PATH" 2>&1 || rc=$?
    printf '%s%s\n' "$IC_RC_TAG" "$rc" >> "$IC_RESULT_PATH"
}

# collect_cases — wait for every case, then print and count results in definition order.
collect_cases() {
    local f line rc_seen
    wait || true
    for f in "${IC_TMP_ROOT:?}"/results/result-*.txt; do
        [[ -f "$f" ]] || continue
        rc_seen=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                "$IC_RC_TAG"*) rc_seen="${line#"$IC_RC_TAG"}"; continue ;;
                "PASS: "*) PASS=$((PASS + 1)) ;;
                "FAIL: "*) FAIL=$((FAIL + 1)) ;;
            esac
            printf '%s\n' "$line"
        done < "$f"
        if [[ "$rc_seen" != "0" ]]; then
            echo "FAIL: ${f##*/}: case aborted before reporting (rc=${rc_seen:-missing})"
            FAIL=$((FAIL + 1))
        fi
    done
}
