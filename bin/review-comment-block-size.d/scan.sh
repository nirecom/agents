#!/bin/bash
#
# bin/review-comment-block-size.d/scan.sh
#
# Sourced by bin/review-comment-block-size; keeps the git plumbing and
# delegates comment recognition to the Node core via scan-cli.js (CPR-SSOT
# with hooks/lib/comment-block-scan.js) so the commit-time CLI and the
# Edit-time hook share one implementation. Must be `source`d, not executed
# directly — reads $T from the caller, publishes SCAN_RUNS / SCAN_N / SCAN_M.

# --- scanner core ----------------------------------------------------------
# scan-cli.js reads a blob or a worktree file on stdin and prints
# "<start> <end> <len>" per run longer than the threshold.
_SCAN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_NODE_SCAN="$_SCAN_DIR/scan-cli.js"

SCAN_RUNS=""
SCAN_N=0
SCAN_M=0

# scan_available — rc 0 when the Node core can actually be reached. The caller
# turns a false here into a SKIPPED report rather than a silent all-clear.
scan_available() {
    command -v node >/dev/null 2>&1 || return 1
    [[ -f "$_NODE_SCAN" ]] || return 1
    return 0
}

scan_tally() {
    local _a _b _len
    SCAN_N=0
    SCAN_M=0
    while read -r _a _b _len; do
        [[ -z "${_len:-}" ]] && continue
        : "$_a" "$_b"
        SCAN_N=$((SCAN_N + 1))
        [[ "$_len" -gt "$SCAN_M" ]] && SCAN_M="$_len"
    done <<< "$SCAN_RUNS"
    return 0
}

# scan_rev <git rev spec> — rc 1 when the blob exists but cannot be read.
scan_rev() {
    local rc=0
    SCAN_RUNS=""
    SCAN_RUNS="$(git show "$1" 2>/dev/null | node "$_NODE_SCAN" --threshold "$T" 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] && return 1
    scan_tally
    return 0
}

# scan_file <worktree path> — rc 1 when the file cannot be read.
scan_file() {
    local rc=0
    SCAN_RUNS=""
    SCAN_RUNS="$(node "$_NODE_SCAN" --threshold "$T" < "$1" 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] && return 1
    scan_tally
    return 0
}
