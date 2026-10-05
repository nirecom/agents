#!/usr/bin/env bash
# m-peak-concurrency.sh — the requested width is the width actually used.
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, scope:issue-specific
# Serial: timing-sensitive parallelism measurements must not compete with other tests

# WHY: other cases prove a parallel run says the right thing but not that it RAN
# at the requested width. Dummies stamp a lock-protected transition log so the
# EXACT peak is pinned; each row also names its own upper bound.

# #2079: the per-run width resolves `-j` > TEST_MAX_JOBS_PER_RUN > .env > default 4,
# and the automatic width never reads the measured record (that is the per-host cap).

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "m-peak-concurrency"

LIB_REL="bin/lib/run-all-parallelism.sh"
LIB="$FX_REPO_ROOT/$LIB_REL"
DEFAULT_MAX_JOBS_PER_RUN=4
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

# write_record <max-jobs-per-host> — a v2 record the reader would call valid for this host.
# Returns 1 when the library cannot name this host, so the caller can fence the row.
write_record() {
    local cap="$1" host os
    [ -f "$LIB" ] || return 1
    host="$(lib_eval 'run_all_host_id')"
    os="$(lib_eval 'run_all_os_attr')"
    [ -n "$host" ] || return 1
    {
        printf 'schema=2\n'
        printf 'host_id=%s\n' "$host"
        printf 'os=%s\n' "$os"
        printf 'max_jobs_per_host=%s\n' "$cap"
        printf 'measured_at=%s\n' "$CAL_AT"
        printf 'sample_size=24\nrepeat=3\n'
    } > "$FX_CACHE_DIR/parallelism.conf"
    return 0
}

# dotenv_stub <value> — a RUN_ALL_CONFIG_VAR_CMD that answers TEST_MAX_JOBS_PER_RUN only.
dotenv_stub() {
    local f="$FX_TMP_ROOT/config-var-stub-$1.sh"
    printf '#!/bin/sh\nif [ "${1:-}" = TEST_MAX_JOBS_PER_RUN ]; then printf "%%s\\n" "%s"; fi\nexit 0\n' "$1" > "$f"
    chmod +x "$f"
    printf '%s' "$f"
}

# peak_case <name> <ndummies> <want-peak> <envspec> <args> <setup>
peak_case() {
    local name="$1" n="$2" want="$3" envspec="$4" args="$5" setup="$6"
    local root out err rc=0 peak starts exec_n
    root="$(build_root "$n")"
    rm -f "$FX_CACHE_DIR/parallelism.conf"

    # `record2`: a valid measured record of 2 that the automatic width must NOT adopt.
    if [ "$setup" = "record2" ] && ! write_record 2; then
        fx_fail "M-$name. cannot build a valid v2 record: run_all_host_id unavailable from $LIB_REL"
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
j1        | 4 | 1 |                          | -j 1 --all    | none
j2        | 6 | 2 |                          | -j 2 --all    | none
j4        | 8 | 4 |                          | -j 4 --all    | none
env3      | 6 | 3 | TEST_MAX_JOBS_PER_RUN=3  | --all         | none
nolib4    | 8 | 4 |                          | -j auto --all | nolib
record2   | 8 | 4 |                          | -j auto --all | record2
defnolib4 | 8 | 4 |                          | --all         | nolib
TABLE

fx_note "the nolib rows pin the built-in max jobs per run ($DEFAULT_MAX_JOBS_PER_RUN) used when $LIB_REL cannot be read"
fx_note "record2 pins that -j auto ignores a measured record of 2 and runs at the default $DEFAULT_MAX_JOBS_PER_RUN"

# ==========================================================================
# M-default. The real default path with -j omitted: the env layer and the .env
# layer each set the width. Two distinct widths are measured so no constant passes.
# ==========================================================================

# Precondition: the env layer really does remove TEST_MAX_JOBS_PER_RUN from the child.
CTL="$(fx_control_args)"
case "$CTL" in
    *"-u TEST_MAX_JOBS_PER_RUN"*) case "$CTL" in
            *"TEST_MAX_JOBS_PER_RUN="*) fx_fail "M-default-pre. TEST_MAX_JOBS_PER_RUN is still passed through to the child: [$CTL]" ;;
            *) fx_pass "M-default-pre. the child env layer removes TEST_MAX_JOBS_PER_RUN outright (-u), so the default path is genuinely unset" ;;
        esac ;;
    *) fx_fail "M-default-pre. want '-u TEST_MAX_JOBS_PER_RUN' in the child env layer, got [$CTL]" ;;
esac

DEF_PEAKS=""

# default_case <layer:env|dotenv> <width> <ndummies> — a measured record of 5 is always
# present, so a run that adopted the record instead of the layer cannot pass.
default_case() {
    local layer="$1" jobs="$2" n="$3" root out err rc=0 peak starts exec_n spec
    root="$(build_root "$n")"
    rm -f "$FX_CACHE_DIR/parallelism.conf"
    write_record 5 || true
    out="$FX_TMP_ROOT/default-$layer.out"; err="$FX_TMP_ROOT/default-$layer.err"
    if [ "$layer" = "env" ]; then spec="TEST_MAX_JOBS_PER_RUN=$jobs"
    else spec="RUN_ALL_CONFIG_VAR_CMD=$(dotenv_stub "$jobs")"; fi
    eval "$spec fx_exec \"\$root\" 120 \"\$out\" \"\$err\" --all" || rc=$?
    peak="$(fx_peak_of "$(fx_peak_log "$root")")"
    starts="$(fx_peak_starts "$(fx_peak_log "$root")")"
    exec_n="$(fx_contract_field "$out" EXECUTED)"
    DEF_PEAKS="$DEF_PEAKS $peak"

    if [ "$exec_n" = "$n" ] && [ "$starts" = "$n" ] && [ "$peak" = "$jobs" ]; then
        fx_pass "M-default-$layer. no -j, the $layer layer says $jobs: EXECUTED=$n and observed peak is exactly $jobs"
    else
        fx_fail "M-default-$layer. want EXECUTED=$n with all $n dummies entered and peak exactly $jobs from the $layer layer, got EXECUTED=${exec_n:-none} entered=$starts peak=$peak (exit $rc)"
    fi
    if [ "$layer" = "dotenv" ]; then
        if [ "$exec_n" = "$n" ] && grep -qF "max jobs per run: $jobs (.env)" "$err"; then
            fx_pass "M-default-dotenv-notice. EXECUTED=$n and stderr states the .env width it adopted"
        else
            fx_fail "M-default-dotenv-notice. want EXECUTED=$n and stderr 'max jobs per run: $jobs (.env)', got EXECUTED=${exec_n:-none}"
        fi
    fi
}

default_case dotenv 2 6
default_case env 3 6

DEF_PEAKS="$(printf '%s' "$DEF_PEAKS" | sed 's/^[[:blank:]]*//')"
if [ "$DEF_PEAKS" = "2 3" ]; then
    fx_pass "M-default-varies. the .env and env layers produced two different peaks ($DEF_PEAKS) — no constant satisfies both"
else
    fx_fail "M-default-varies. want peaks '2 3' from .env=2 and env=3 with -j omitted, got '$DEF_PEAKS'"
fi

[ "$FX_ERRORS" -eq 0 ] || fx_show_tail "$FX_TMP_ROOT/j4.err" 10

fx_finish
