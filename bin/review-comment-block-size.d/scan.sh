#!/bin/bash
#
# bin/review-comment-block-size.d/scan.sh
#
# Sourced by bin/review-comment-block-size. The scanner core: the awk program
# that finds over-threshold comment runs, plus the two entry points that feed
# it a staged blob (scan_rev) or a worktree file (scan_file).
#
# Must be `source`d, not executed directly — it reads $T from the caller and
# publishes its results in SCAN_RUNS / SCAN_N / SCAN_M.

# --- scanner core ----------------------------------------------------------
# One pass, one state bit (inb = inside a /* ... */ block). Reads a blob or a
# worktree file on stdin and prints "<start> <end> <len>" per over-threshold run.
_AWK='
BEGIN { inb = 0; run = 0; st = 0 }
{
    s = $0
    sub(/\r$/, "", s)
    sub(/^[ \t]+/, "", s)
    c = 0
    if (NR == 1 && substr(s, 1, 2) == "#!") {
        c = 0
    } else if (inb == 1) {
        c = 1
        if (index(s, "*/") > 0) { inb = 0 }
    } else if (substr(s, 1, 2) == "/*") {
        c = 1
        if (index(substr(s, 3), "*/") == 0) { inb = 1 }
    } else if (substr(s, 1, 2) == "//" || substr(s, 1, 1) == "#" || substr(s, 1, 2) == "*/") {
        c = 1
    } else if (substr(s, 1, 1) == "*" && (length(s) == 1 || substr(s, 2, 1) == " " || substr(s, 2, 1) == "\t")) {
        c = 1
    }
    if (c == 1) {
        if (run == 0) { st = NR }
        run = run + 1
    } else {
        if (run >= T) { print st, st + run - 1, run }
        run = 0
    }
}
END { if (run >= T) { print st, st + run - 1, run } }
'

SCAN_RUNS=""
SCAN_N=0
SCAN_M=0

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
    SCAN_RUNS="$(git show "$1" 2>/dev/null | awk -v T="$T" "$_AWK")" || rc=$?
    [[ "$rc" -ne 0 ]] && return 1
    scan_tally
    return 0
}

# scan_file <worktree path> — rc 1 when the file cannot be read.
scan_file() {
    local rc=0
    SCAN_RUNS=""
    SCAN_RUNS="$(awk -v T="$T" "$_AWK" < "$1" 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] && return 1
    scan_tally
    return 0
}
