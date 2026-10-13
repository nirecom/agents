#!/usr/bin/env bash
# One test re-run at the merge base for bin/run-tests-baseline (#2431). Source-only.
# rtb_exec_one <wt> <rel-path> <timeout> <logdir> launches through run_all_exec (the
# checkout's own bin/lib/run-all-launch.sh when present, else this checkout's), so each
# test kind starts exactly as tests/run-all.sh would start it. The launcher's TIMEOUT is the
# authority (RUN_ALL_TIMEOUT_SECONDS); the watchdog is a +10 s backstop. The default <timeout>
# is owned by run-tests-baseline-timeout.sh (RTB_TIMEOUT_DEFAULT). Outcomes come from
# <logdir>/<i>.{state,timedout,unrunnable,unsupported,decoyhit} markers, never from the exit
# code alone: RTB_EXEC_STATE ("" from a launcher that predates #2501), RTB_EXEC_TIMEDOUT,
# RTB_EXEC_UNRUNNABLE, RTB_EXEC_UNSUPPORTED (not launched, so a test exiting 78 is not it),
# RTB_EXEC_DECOY (the run reached the root decoy: its exit code says nothing about the base).

case "${BASH_SOURCE[0]}" in
  */*) RTB_EXEC_LIB_DIR="${BASH_SOURCE[0]%/*}" ;;
  *)   RTB_EXEC_LIB_DIR="." ;;
esac
# shellcheck source=bin/lib/run-tests-baseline-timeout.sh
. "$RTB_EXEC_LIB_DIR/run-tests-baseline-timeout.sh" || return 1

RTB_EXEC_RC=""
RTB_EXEC_TIMEDOUT=""
RTB_EXEC_UNSUPPORTED=""
RTB_EXEC_DECOY=""
RTB_EXEC_STATE=""
RTB_EXEC_UNRUNNABLE=""
RTB_EXEC_SEQ=0

# rtb_exec_kill_group <pid> <signal> — the job's process group first, the pid as fallback.
rtb_exec_kill_group() {
    kill "-$2" -- "-$1" 2>/dev/null || kill "-$2" "$1" 2>/dev/null || true
}

# rtb_base_predates_root_names <root> <commit> — 0 when <commit> carries a top-level
# profile-snippet.sh that does not name AGENTS_MAIN_ROOT (its tests cannot run under
# today's root names); 1 otherwise, including when the commit has no such file.
rtb_base_predates_root_names() {
    local root="${1:-}" commit="${2:-}" body
    [ -n "$root" ] && [ -n "$commit" ] || return 1
    body="$(git -C "$root" show "$commit:profile-snippet.sh" 2>/dev/null)" || return 1
    case "$body" in *AGENTS_MAIN_ROOT*) return 1 ;; esac
    return 0
}

rtb_exec_one() {
    local wt="${1:-}" rel="${2:-}" timeout="${3:-$RTB_TIMEOUT_DEFAULT}" logdir="${4:-}"
    local launcher i cpid wpid rc iso restore_m=0
    RTB_EXEC_RC=""
    RTB_EXEC_TIMEDOUT=""
    RTB_EXEC_UNSUPPORTED=""
    RTB_EXEC_DECOY=""
    RTB_EXEC_STATE=""
    RTB_EXEC_UNRUNNABLE=""
    [ -n "$wt" ] && [ -n "$rel" ] && [ -n "$logdir" ] || return 2
    case "$timeout" in ''|*[!0-9]*) timeout="$RTB_TIMEOUT_DEFAULT" ;; esac
    mkdir -p "$logdir" 2>/dev/null || return 2

    launcher="$wt/bin/lib/run-all-launch.sh"
    [ -f "$launcher" ] || launcher="$RTB_EXEC_LIB_DIR/run-all-launch.sh"
    [ -f "$launcher" ] || return 2
    # Per-run workflow/plans/transcript dirs: a base test must never resolve the live
    # session or write real workflow state. HOME stays (the run_all cache lives there).
    iso="$(mktemp -d 2>/dev/null)" || return 2
    if command -v cygpath >/dev/null 2>&1; then iso="$(cygpath -m "$iso")"; fi
    mkdir -p "$iso/workflow" "$iso/plans" "$iso/transcripts" 2>/dev/null || { rm -rf "$iso"; return 2; }

    RTB_EXEC_SEQ=$((RTB_EXEC_SEQ + 1))
    i="$RTB_EXEC_SEQ"
    rm -f "$logdir/$i.timedout" "$logdir/$i.nolaunch" "$logdir/$i.unsupported" "$logdir/$i.decoyhit" \
        "$logdir/$i.state" "$logdir/$i.unrunnable"

    # Job control gives each background job its own process group, so the watchdog
    # can take down the whole test tree, not just the launching subshell.
    case "$-" in *m*) ;; *) set -m; restore_m=1 ;; esac
    (
        # Base code is sourced only in this subshell, so it cannot rewrite RTB_* state;
        # a setup failure is flagged apart from the test's own exit code.
        # shellcheck source=bin/lib/run-all-launch.sh
        . "$launcher" || { : >"$logdir/$i.nolaunch"; exit 2; }
        cd "$wt" || { : >"$logdir/$i.nolaunch"; exit 2; }
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
        unset RUN_ALL_EXEC_STATE RUN_ALL_EXEC_MISSING RUN_ALL_EXEC_LAUNCHED
        export WORKFLOW_STATE_DIR="$iso/workflow" \
            WORKFLOW_PLANS_DIR="$iso/plans" CLAUDE_TRANSCRIPT_BASE_DIR="$iso/transcripts" \
            RUN_ALL_TIMEOUT_SECONDS="$timeout"
        # The base test finds its tools from its own checkout; the launcher's decoy pin
        # makes any reach through a root variable visible instead of silently working.
        if declare -F run_all_pin_root_decoy >/dev/null 2>&1; then
            run_all_pin_root_decoy || { : >"$logdir/$i.nolaunch"; exit 2; }
        fi
        run_all_exec "$wt/$rel" "$logdir/$i.out" "$logdir/$i.err"
        rc=$?
        [ "$rc" = 78 ] && [ "${RUN_ALL_EXEC_LAUNCHED:-1}" = 0 ] && : >"$logdir/$i.unsupported"
        # The launcher could not set the test up (its own rc 2): the test never ran, so no verdict.
        [ "$rc" = 2 ] && [ "${RUN_ALL_EXEC_LAUNCHED:-1}" = 0 ] && : >"$logdir/$i.nolaunch"
        if [ -n "${RUN_ALL_EXEC_STATE:-}" ]; then
            printf '%s\n' "$RUN_ALL_EXEC_STATE" >"$logdir/$i.state"
            [ "$RUN_ALL_EXEC_STATE" = TIMEOUT ] && : >"$logdir/$i.timedout"
            [ "$RUN_ALL_EXEC_STATE" = UNRUNNABLE ] \
                && printf '%s\n' "${RUN_ALL_EXEC_MISSING:-unknown}" >"$logdir/$i.unrunnable"
        fi
        # A base test that reached the decoy is not a valid green, as in tests/run-all.sh.
        if declare -F run_all_root_decoy_report >/dev/null 2>&1; then
            run_all_root_decoy_report 2>>"$logdir/$i.err" || { : >"$logdir/$i.decoyhit"; [ "$rc" = 0 ] && rc=1; }
        fi
        exit "$rc"
    )</dev/null >/dev/null 2>&1 &
    cpid=$!
    (
        sleep "$((timeout + 10))"
        : >"$logdir/$i.timedout"
        rtb_exec_kill_group "$cpid" TERM
        sleep 2
        rtb_exec_kill_group "$cpid" KILL
    ) </dev/null >/dev/null 2>&1 &
    wpid=$!
    [ "$restore_m" -eq 1 ] && set +m

    wait "$cpid" 2>/dev/null
    rc=$?
    rtb_exec_kill_group "$wpid" TERM
    wait "$wpid" 2>/dev/null || true
    rm -rf "$iso" 2>/dev/null || true
    [ -e "$logdir/$i.nolaunch" ] && return 2

    # shellcheck disable=SC2034  # outputs read by the sourcing caller
    RTB_EXEC_RC="$rc"
    # shellcheck disable=SC2034
    if [ -e "$logdir/$i.timedout" ]; then RTB_EXEC_TIMEDOUT=1; else RTB_EXEC_TIMEDOUT=0; fi
    # shellcheck disable=SC2034
    if [ -e "$logdir/$i.unsupported" ]; then RTB_EXEC_UNSUPPORTED=1; else RTB_EXEC_UNSUPPORTED=0; fi
    # shellcheck disable=SC2034
    if [ -e "$logdir/$i.decoyhit" ]; then RTB_EXEC_DECOY=1; else RTB_EXEC_DECOY=0; fi
    # shellcheck disable=SC2034
    if [ -e "$logdir/$i.unrunnable" ]; then RTB_EXEC_UNRUNNABLE=1; else RTB_EXEC_UNRUNNABLE=0; fi
    # shellcheck disable=SC2034
    if [ -f "$logdir/$i.state" ]; then RTB_EXEC_STATE="$(tr -d '\r\n' <"$logdir/$i.state")"; fi
    return 0
}
