#!/usr/bin/env bash
# m-peak-concurrency.sh — the requested width is the width actually used.
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, scope:issue-specific
# Serial: timing-sensitive parallelism measurements must not compete with other tests

# WHY: other cases prove a parallel run says the right thing but not that it RAN
# at the requested width. Dummies stamp a lock-protected transition log so the
# EXACT peak is pinned; each row also names its own upper bound.

# RED-FIRST: `-j` / `-j auto` and the parallel dispatcher don't exist yet, so
# `-j N --all` currently parses/executes/reports nothing.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "m-peak-concurrency"

LIB_REL="bin/lib/run-all-parallelism.sh"
LIB="$FX_REPO_ROOT/$LIB_REL"
FALLBACK_JOBS=4
DUMMY_SLEEP=2
CAL_AT="2026-01-02T03:04:05Z"

trim() { printf '%s' "$1" | sed 's/^[[:blank:]]*//; s/[[:blank:]]*$//'; }

# lib_eval <snippet> — stdout of the snippet with the parallelism library
# sourced, or the empty string when the library has not landed yet.
lib_eval() {
    [ -f "$LIB" ] || return 0
    run_with_timeout 30 bash -c \
        'set -u; . "$0" >/dev/null 2>&1 || exit 0; eval "$1"' "$LIB" "$1" 2>/dev/null
}

# build_root <ndummies> — a fixture whose dummies stamp the transition log.
build_root() {
    local n="$1" i root
    root="$(fx_new_root)"
    i=1
    while [ "$i" -le "$n" ]; do
        fx_add_dummy "$root" "q$i" --sleep "$DUMMY_SLEEP" --peak --lines 1
        i=$((i + 1))
    done
    echo "$root"
}

# write_cache <root> <ndummies> <jobs> — a cache the library would call valid.
# Returns 1 when the library is absent, so the caller can fence the row.
write_cache() {
    local root="$1" n="$2" jobs="$3" host bucket
    [ -f "$LIB" ] || return 1
    host="$(lib_eval 'run_all_host_id')"
    bucket="$(TESTS_DIR="$(fx_tests_dir "$root")" lib_eval "run_all_count_bucket $n")"
    [ -n "$host" ] && [ -n "$bucket" ] || return 1
    {
        printf 'schema=%s\n' "$(lib_eval 'printf "%s" "${RUN_ALL_CACHE_SCHEMA:-1}"')"
        printf 'host_id=%s\n' "$host"
        printf 'count_bucket=%s\n' "$bucket"
        printf 'jobs=%s\n' "$jobs"
        printf 'measured_at=%s\n' "$CAL_AT"
        printf 'sample_size=24\nrepeat=3\n'
    } > "$FX_CACHE_DIR/parallelism.conf"
    return 0
}

# peak_case <name> <ndummies> <want-peak> <envspec> <args> <setup>
peak_case() {
    local name="$1" n="$2" want="$3" envspec="$4" args="$5" setup="$6"
    local root out err rc=0 peak starts exec_n
    root="$(build_root "$n")"
    rm -f "$FX_CACHE_DIR/parallelism.conf"

    if [ "$setup" = "cache" ] && ! write_cache "$root" "$n" "$want"; then
        fx_fail "M-$name. cannot build a valid jobs=$want cache: implementation missing: $LIB_REL"
        fx_fail "M-$name-bound. upper bound unverifiable for the same reason"
        return 0
    fi
    [ "$setup" = "nolib" ] && envspec="RUN_ALL_PARALLELISM_LIB=$FX_TMP_ROOT/absent-lib.sh"

    out="$FX_TMP_ROOT/$name.out"; err="$FX_TMP_ROOT/$name.err"
    eval "$envspec fx_exec \"\$root\" 120 \"\$out\" \"\$err\" $args" || rc=$?
    peak="$(fx_peak_of "$(fx_peak_log "$root")")"
    starts="$(fx_peak_starts "$(fx_peak_log "$root")")"
    exec_n="$(fx_contract_field "$out" EXECUTED)"

    if [ "$exec_n" = "$n" ] && [ "$starts" = "$n" ] && [ "$peak" = "$want" ]; then
        fx_pass "M-$name. $n dummies, EXECUTED=$n: observed peak $peak == requested width $want"
    else
        fx_fail "M-$name. want EXECUTED=$n with all $n dummies entered and peak exactly $want, got EXECUTED=${exec_n:-none} entered=$starts peak=$peak (exit $rc)"
    fi

    if [ "$starts" = "$n" ] && [ "$peak" -le "$want" ] 2>/dev/null; then
        fx_pass "M-$name-bound. peak $peak never exceeded the requested width $want"
    else
        fx_fail "M-$name-bound. want all $n dummies entered and peak <= $want, got entered=$starts peak=$peak"
    fi
}

# Every row runs at least 2x its width in dummies, so the width is reachable:
# an implementation that never fills the pool cannot pass by running out of work.
while IFS='|' read -r name n want envspec args setup; do
    case "$name" in ''|\#*) continue ;; esac
    peak_case "$(trim "$name")" "$(trim "$n")" "$(trim "$want")" \
        "$(trim "$envspec")" "$(trim "$args")" "$(trim "$setup")"
done <<'TABLE'
j1        | 4 | 1 |                 | -j 1 --all    | none
j2        | 6 | 2 |                 | -j 2 --all    | none
j4        | 8 | 4 |                 | -j 4 --all    | none
env3      | 6 | 3 | RUN_ALL_JOBS=3  | --all         | none
nolib4    | 8 | 4 |                 | -j auto --all | nolib
cache2    | 6 | 2 |                 | -j auto --all | cache
defnolib4 | 8 | 4 |                 | --all         | nolib
TABLE

fx_note "the nolib rows pin RUN_ALL_FALLBACK_JOBS=$FALLBACK_JOBS as the width used when $LIB_REL cannot be read"
fx_note "defnolib4 is the -j-omitted default path with no library: it must resolve a width on its own, not run serially"

# ==========================================================================
# M-default. The real default path: valid cache, no -j in argv, RUN_ALL_JOBS
# unset. Two distinct cached widths are measured so no hardcoded constant passes.
# ==========================================================================

# Precondition: the env layer really does remove RUN_ALL_JOBS from the child.
CTL="$(fx_control_args)"
case "$CTL" in
    *"-u RUN_ALL_JOBS"*) case "$CTL" in
            *"RUN_ALL_JOBS="*) fx_fail "M-default-pre. RUN_ALL_JOBS is still passed through to the child: [$CTL]" ;;
            *) fx_pass "M-default-pre. the child env layer removes RUN_ALL_JOBS outright (-u), so the default path is genuinely unset" ;;
        esac ;;
    *) fx_fail "M-default-pre. want '-u RUN_ALL_JOBS' in the child env layer, got [$CTL]" ;;
esac

DEF_PEAKS=""

# default_case <cached-jobs> <ndummies>
default_case() {
    local jobs="$1" n="$2" root out err rc=0 peak starts exec_n
    root="$(build_root "$n")"
    rm -f "$FX_CACHE_DIR/parallelism.conf"
    if ! write_cache "$root" "$n" "$jobs"; then
        fx_fail "M-default$jobs. cannot build a valid jobs=$jobs cache: implementation missing: $LIB_REL"
        fx_fail "M-default$jobs-notice. the calibrated-width notice is unverifiable for the same reason"
        DEF_PEAKS="$DEF_PEAKS -"
        return 0
    fi
    out="$FX_TMP_ROOT/default$jobs.out"; err="$FX_TMP_ROOT/default$jobs.err"
    fx_exec "$root" 120 "$out" "$err" --all || rc=$?
    peak="$(fx_peak_of "$(fx_peak_log "$root")")"
    starts="$(fx_peak_starts "$(fx_peak_log "$root")")"
    exec_n="$(fx_contract_field "$out" EXECUTED)"
    DEF_PEAKS="$DEF_PEAKS $peak"

    if [ "$exec_n" = "$n" ] && [ "$starts" = "$n" ] && [ "$peak" = "$jobs" ]; then
        fx_pass "M-default$jobs. no -j, RUN_ALL_JOBS unset, cache says jobs=$jobs: EXECUTED=$n and observed peak is exactly $jobs"
    else
        fx_fail "M-default$jobs. want EXECUTED=$n with all $n dummies entered and peak exactly $jobs from the cache alone, got EXECUTED=${exec_n:-none} entered=$starts peak=$peak (exit $rc)"
    fi

    if [ "$exec_n" = "$n" ] && grep -qF "[run-all] parallelism: -j $jobs (calibrated $CAL_AT)" "$err"; then
        fx_pass "M-default$jobs-notice. EXECUTED=$n and stderr states the cached width it adopted"
    else
        fx_fail "M-default$jobs-notice. want EXECUTED=$n and stderr '[run-all] parallelism: -j $jobs (calibrated $CAL_AT)', got EXECUTED=${exec_n:-none}"
    fi
}

default_case 2 6
default_case 3 6

DEF_PEAKS="$(printf '%s' "$DEF_PEAKS" | sed 's/^[[:blank:]]*//')"
if [ "$DEF_PEAKS" = "2 3" ]; then
    fx_pass "M-default-varies. the two cached widths produced two different peaks ($DEF_PEAKS) — no constant satisfies both"
else
    fx_fail "M-default-varies. want peaks '2 3' from caches jobs=2 and jobs=3 with -j omitted, got '$DEF_PEAKS'"
fi

[ "$FX_ERRORS" -eq 0 ] || fx_show_tail "$FX_TMP_ROOT/j4.err" 10

fx_finish
