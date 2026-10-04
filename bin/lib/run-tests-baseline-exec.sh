#!/usr/bin/env bash
# One test re-run at the merge base for bin/run-tests-baseline (#2431). Source-only.
# rtb_exec_one <wt> <rel-path> <timeout> <logdir> launches through run_all_exec (the
# checkout's own bin/lib/run-all-launch.sh when present, else this checkout's), so each
# test kind starts exactly as tests/run-all.sh would start it. A watchdog enforces the
# timeout; RTB_EXEC_TIMEDOUT comes from <logdir>/<i>.timedout, never from the exit code.

case "${BASH_SOURCE[0]}" in
  */*) RTB_EXEC_LIB_DIR="${BASH_SOURCE[0]%/*}" ;;
  *)   RTB_EXEC_LIB_DIR="." ;;
esac

RTB_EXEC_RC=""
RTB_EXEC_TIMEDOUT=""
RTB_EXEC_SEQ=0

# rtb_exec_kill_group <pid> <signal> — the job's process group first, the pid as fallback.
rtb_exec_kill_group() {
    kill "-$2" -- "-$1" 2>/dev/null || kill "-$2" "$1" 2>/dev/null || true
}

rtb_exec_one() {
    local wt="${1:-}" rel="${2:-}" timeout="${3:-300}" logdir="${4:-}"
    local launcher i cpid wpid rc iso restore_m=0
    RTB_EXEC_RC=""
    RTB_EXEC_TIMEDOUT=""
    [ -n "$wt" ] && [ -n "$rel" ] && [ -n "$logdir" ] || return 2
    case "$timeout" in ''|*[!0-9]*) timeout=300 ;; esac
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
    rm -f "$logdir/$i.timedout" "$logdir/$i.nolaunch"

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
        export AGENTS_CONFIG_DIR="$wt" WORKFLOW_STATE_DIR="$iso/workflow" \
            WORKFLOW_PLANS_DIR="$iso/plans" CLAUDE_TRANSCRIPT_BASE_DIR="$iso/transcripts"
        run_all_exec "$wt/$rel" "$logdir/$i.out" "$logdir/$i.err"
    ) </dev/null >/dev/null 2>&1 &
    cpid=$!
    (
        sleep "$timeout"
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
    return 0
}
