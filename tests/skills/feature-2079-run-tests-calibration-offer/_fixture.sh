#!/usr/bin/env bash
# tests/skills/feature-2079-run-tests-calibration-offer/_fixture.sh — shared fixture (SOURCE ONLY).
# Fake worktrees (<cwd>/bin/test-lanes-status.sh and <cwd>/bin/calibrate-test-parallelism.sh
# stubs driven by data files), script runners that set OUT/ERR/RC, and record/marker helpers.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "SKIP: _fixture.sh is a sourceable library, not a test" >&2
    exit 77
fi

# The host id the real lib derives here; a never-ask record for this host carries it.
HID="$(bash -c '. "$1" >/dev/null 2>&1; declare -F run_all_host_id >/dev/null && run_all_host_id' _ "$PAR_LIB" 2>/dev/null)"
HID_DIGEST="${HID##*|}"
NOTICE_HINT="RUN_CALIBRATION=1 bash bin/calibrate-test-parallelism.sh"
NOTICE_TAIL="measure once with: $NOTICE_HINT (up to 90 min; --dry-run shows the cost; docs/ops.md \"Test parallelism calibration\")"

# mk_cwd <dir> <status-line-1> [status-rc] — a fake worktree. The status stub prints
# <dir>/status.line verbatim and exits <dir>/status.rc; the calibrator stub logs what it
# received to <dir>/cal.log, copies <dir>/cal.line over status.line (a "new record"), and
# exits <dir>/cal.rc.
mk_cwd() {
    mkdir -p "$1/bin"
    printf '%s\n' "$2" > "$1/status.line"
    printf '%s\n' "${3:-0}" > "$1/status.rc"
    printf '%s\n' '#!/usr/bin/env bash' 'd="$(cd "$(dirname "$0")/.." && pwd)"' \
        'cat "$d/status.line"' 'exit "$(cat "$d/status.rc" 2>/dev/null || echo 0)"' \
        > "$1/bin/test-lanes-status.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'd="$(cd "$(dirname "$0")/.." && pwd)"' \
        'printf "RUN_CALIBRATION=%s\n" "${RUN_CALIBRATION-unset}" >> "$d/cal.log"' \
        'printf "pwd=%s\n" "$(pwd -P)" >> "$d/cal.log"' \
        'printf "args=%s\n" "$#" >> "$d/cal.log"' \
        '[ -f "$d/cal.line" ] && cp "$d/cal.line" "$d/status.line"' \
        'exit "$(cat "$d/cal.rc" 2>/dev/null || echo 0)"' \
        > "$1/bin/calibrate-test-parallelism.sh"
    chmod +x "$1/bin/test-lanes-status.sh" "$1/bin/calibrate-test-parallelism.sh" 2>/dev/null || true
}

# na_rec <cache> <host_id> — a well-formed never-ask record.
na_rec() {
    mkdir -p "$1"
    printf 'schema=1\nhost_id=%s\nrecorded_at=2026-01-01T00:00:00Z\n' "$2" > "$1/calibration-never-ask.conf"
}

# marker_of <sid> — where the session marker lives (bin/workflow-control-dir layout).
marker_of() { printf '%s/%s.control/calibration-asked.txt' "$WORKFLOW_STATE_DIR" "$1"; }

OUT=""; ERR=""; RC=0
# run_script <script> <cache> [NAME=VAL ...] -- [args...] — from a neutral cwd; sets OUT/ERR/RC.
run_script() {
    local script="$1" cache="$2"; shift 2
    local -a envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ "$#" -gt 0 ] && shift
    RC=0
    (
        cd "$NEUTRAL_DIR" || exit 99
        run_with_timeout 60 env "RUN_ALL_CACHE_DIR=$cache" ${envs[@]+"${envs[@]}"} bash "$script" "$@"
    ) >"$TMPROOT/run.out" 2>"$TMPROOT/run.err" || RC=$?
    OUT="$(cat "$TMPROOT/run.out")"
    ERR="$(cat "$TMPROOT/run.err")"
}

# probe <cwd> <sid> [cache] / mark <sid> [cache] / answer <verb> <cwd> <sid> [cache]
probe() { run_script "$PROBE" "${3:-$CACHE}" -- --cwd "$1" --session "$2"; }
mark() { run_script "$MARK" "${2:-$CACHE}" -- --session "$1"; }
answer() { run_script "$ANSWER" "${4:-$CACHE}" -- "$1" --cwd "$2" --session "$3"; }

# kv <key> — value of the first `key=` line of OUT.
kv() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -n 1; }
kv_count() { printf '%s\n' "$OUT" | grep -c "^$1=" || true; }

# content_sig <dir...> — every path, plus a cksum of each regular file's bytes (mtime-blind),
# so a rewrite in place changes it; "absent" for a missing dir.
content_sig() {
    local d f
    for d in "$@"; do
        if [ -d "$d" ]; then
            (cd "$d" && find . -print | LC_ALL=C sort | while IFS= read -r f; do
                if [ -f "$f" ]; then printf '%s %s\n' "$f" "$(cksum < "$f")"; else printf '%s\n' "$f"; fi
            done)
        else echo "absent:$d"; fi
    done
}

# marker_sig — every session marker, control dir and temp file under TMPROOT, plus the
# workflow dir's content: a write anywhere by a hostile session id changes it.
marker_sig() {
    (cd "$TMPROOT" && find . \( -name 'calibration-asked.txt' -o -name '*.control' -o -name '*.tmp' \) -print | LC_ALL=C sort)
    content_sig "$WORKFLOW_STATE_DIR"
}

# ends_nl <file> — "yes" when the file is non-empty and its last byte is a newline (no torn line).
ends_nl() { if [ -s "$1" ] && [ -z "$(tail -c 1 "$1")" ]; then echo yes; else echo no; fi; }

grp_done _fixture.sh
