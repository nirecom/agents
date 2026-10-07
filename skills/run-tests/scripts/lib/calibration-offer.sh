#!/usr/bin/env bash
# Shared helpers for the /run-tests calibration offer (SOURCE ONLY): argument parsing,
# the session marker, and the notice line. Every input is treated as data, never as code.

CO_SID=""
CO_CWD=""
CO_HAVE_SID=0
CO_HAVE_CWD=0

co_usage_error() {
    printf '%s: %s\n' "$(basename "$0")" "$1" >&2
    exit 2
}

# co_parse_args <need_cwd> [args...] - sets CO_SID / CO_CWD; exit 2 on any usage error.
co_parse_args() {
    local need_cwd="$1"
    shift
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --session)
                [ "$#" -ge 2 ] || co_usage_error "--session needs a value"
                CO_SID="$2"; CO_HAVE_SID=1; shift 2 ;;
            --cwd)
                [ "$#" -ge 2 ] || co_usage_error "--cwd needs a value"
                CO_CWD="$2"; CO_HAVE_CWD=1; shift 2 ;;
            *) co_usage_error "unknown argument: $1" ;;
        esac
    done
    [ "$CO_HAVE_SID" -eq 1 ] && [ -n "$CO_SID" ] || co_usage_error "--session <sid> is required"
    if [ "$need_cwd" -eq 1 ]; then
        [ "$CO_HAVE_CWD" -eq 1 ] && [ -n "$CO_CWD" ] || co_usage_error "--cwd <dir> is required"
    elif [ "$CO_HAVE_CWD" -eq 1 ]; then
        co_usage_error "unknown argument: --cwd"
    fi
}

co_agents_root() {
    (cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
}

co_source_parallelism_lib() {
    local lib
    lib="$(co_agents_root)/bin/lib/run-all-parallelism.sh"
    [ -f "$lib" ] || return 1
    # shellcheck source-path=SCRIPTDIR source=../../../../bin/lib/run-all-parallelism.sh
    . "$lib"
}

# co_marker_path <sid> [--for-write] - prints the marker path; non-zero when the sid is refused.
co_marker_path() {
    local sid="$1"
    shift
    node "$(co_agents_root)/bin/workflow-control-dir" --session "$sid" --file calibration-asked.txt "$@" 2>/dev/null
}

# co_marker_write <sid> <line> - appends one whole line to the session marker.
co_marker_write() {
    local path
    path="$(co_marker_path "$1" --for-write)" || return 1
    [ -n "$path" ] || return 1
    [ ! -L "$path" ] || return 1
    { printf '%s\n' "$2" >> "$path"; } 2>/dev/null
}

# co_notice <lead> <reason> - the one-line notice; the hint and time limit come from the parallelism lib.
co_notice() {
    printf 'calibration: %s (%s); measure once with: %s (up to %s min; --dry-run shows the cost; docs/ops.md "Test parallelism calibration")\n' \
        "$1" "$2" "$RUN_ALL_CALIBRATOR_HINT" "$RUN_ALL_CALIBRATION_TIME_LIMIT_MIN"
}
