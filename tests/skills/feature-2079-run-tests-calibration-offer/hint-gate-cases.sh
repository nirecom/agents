#!/usr/bin/env bash
# tests/skills/feature-2079-run-tests-calibration-offer/hint-gate-cases.sh — P9.
# The printed hint, run verbatim from the repo root, passes the calibrator's opt-in gate and
# publishes a record the reader accepts; the same command without its prefix stays gated.
# The measurement itself is replaced by the RUN_ALL_CALIBRATION_MEASURE_CMD seam (constant
# 1000 ms per call), over a synthetic 30-test corpus whose ledger fills the 5-10 s band.
# P9_SMALL is appended after the verbatim hint: the default ladder (5 widths x 4 passes over
# 48 tests) costs ~100 s of calibrator overhead on Windows even with a no-op seam, and the
# flags change only the ladder size, never the gate this case is about.

case_begin "hint-opens-the-gate" "bin/lib/run-all-parallelism.sh"

P9_HINT="$(bash -c '. "$1" >/dev/null 2>&1; printf "%s" "${RUN_ALL_CALIBRATOR_HINT-}"' _ "$PAR_LIB" 2>/dev/null)"
ck "P9 the hint is the runnable command" "RUN_CALIBRATION=1 bash bin/calibrate-test-parallelism.sh" "$P9_HINT"
P9_SMALL="--sample 4 --jobs-list '1 2' --repeat 3 --warmup 0"
P9_RES="$TMPROOT/p9.results"
: > "$P9_RES"
P9_GIT_BEFORE="$(git -C "$SCRIPT_CHECKOUT_ROOT" status --porcelain 2>/dev/null)"
if [ -n "$P9_HINT" ]; then
    (
        # shellcheck source=../../tests/feature-1832-run-all-parallel/_cal-fixture.sh
        . "$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-1832-run-all-parallel/_cal-fixture.sh"
        cf_init
        S="$(cf_new_suite)"; R="$(cf_new_real)"
        cf_populate "$S" "$R" bin/a 30 6
        ST="$(cf_stub_drift 1000 0)"
        p9_run() {
            local cmd="$1" rc=0
            (
                cd "$CF_REPO" || exit 99
                run_with_timeout 110 env -u RUN_CALIBRATION "RUN_ALL_CACHE_DIR=$R" "TESTS_DIR=$S" \
                    "RUN_ALL_CONFIG_VAR_CMD=$CF_T/no-such-config-resolver" \
                    "RUN_ALL_CALIBRATION_MEASURE_CMD=$ST/measure.sh" bash -c "$cmd"
            ) >"$CF_T/p9.out" 2>"$CF_T/p9.err" || rc=$?
            printf '%s' "$rc"
        }
        rc="$(p9_run "$P9_HINT $P9_SMALL")"
        printf 'hint_rc=%s\n' "$rc"
        grep -q 'refusing to measure' "$CF_T/p9.err" && printf 'hint_refused=yes\n' || printf 'hint_refused=no\n'
        printf 'hint_calls=%s\n' "$(cf_calls "$ST")"
        if env "TESTS_DIR=$S" bash -c '. "$1" >/dev/null 2>&1 || exit 9; run_all_cache_read "$2"' _ "$CF_LIB_PAR" "$R/parallelism.conf" >/dev/null 2>&1; then
            printf 'record=accepted\n'
        else
            printf 'record=rejected\n'
        fi
        rm -f "$R/parallelism.conf"
        : > "$ST/calls.log"
        rc="$(p9_run "${P9_HINT#RUN_CALIBRATION=1 } $P9_SMALL")"
        printf 'bare_rc=%s\n' "$rc"
        printf 'bare_calls=%s\n' "$(cf_calls "$ST")"
        [ -e "$R/parallelism.conf" ] && printf 'bare_record=yes\n' || printf 'bare_record=no\n'
    ) > "$P9_RES" 2>"$TMPROOT/p9.subshell.err"
fi
p9_kv() { sed -n "s/^$1=//p" "$P9_RES" | head -n 1; }
ck "P9 hint run as printed: exit 0" "0" "$(p9_kv hint_rc)"
ck "P9 hint run as printed: the gate does not refuse" "no" "$(p9_kv hint_refused)"
_calls="$(p9_kv hint_calls)"
[ -n "$_calls" ] && [ "$_calls" -gt 0 ] && pass "P9 hint run as printed: the measurement seam ran ($_calls calls)" || fail "P9 hint run as printed: the measurement seam never ran" "calls=${_calls:-none}"
ck "P9 hint run as printed: the published record is accepted by run_all_cache_read" "accepted" "$(p9_kv record)"
ck "P9 control without RUN_CALIBRATION=1: exit 77" "77" "$(p9_kv bare_rc)"
ck "P9 control without RUN_CALIBRATION=1: no seam call" "0" "$(p9_kv bare_calls)"
ck "P9 control without RUN_CALIBRATION=1: no record" "no" "$(p9_kv bare_record)"
ck "P9 the repo working tree is unchanged by the runs" "$P9_GIT_BEFORE" "$(git -C "$SCRIPT_CHECKOUT_ROOT" status --porcelain 2>/dev/null)"
case_ran P9

case_end

grp_done hint-gate-cases.sh
