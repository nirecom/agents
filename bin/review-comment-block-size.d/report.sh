#!/bin/bash
# bin/review-comment-block-size.d/report.sh — sourced by bin/review-comment-block-size,
# not executed directly. Defines caller-scope globals (ESC, BODY, WARNC, ERRC, SCANNED,
# TOOBIG, LABEL); owns escaping + buffering findings until the header's counts are known.

# --- output escaping -------------------------------------------------------
# Paths arrive from `git ... -z` (raw bytes, ignores core.quotePath) and $_EXTS
# from the environment; both print into a line-oriented report that hooks/pre-commit
# re-prints verbatim, so an LF forges a finding line and an ESC repaints the reader's
# terminal. C0 control bytes + 0x7F render as \xHH (uppercase); backslash is data,
# never doubled; non-ASCII passes through untouched. Tables built once — no per-call fork.
_CTL_HEX=(01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F
          10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F 7F)
_CTL_BYTE=()
_CTL_REPL=()
for _h in "${_CTL_HEX[@]}"; do
    printf -v _b "\\x$_h"
    _CTL_BYTE+=("$_b")
    _CTL_REPL+=('\x'"$_h")
done
unset _h _b

# esc <string> — escaped result lands in $ESC (a global: a command substitution
# would fork a subshell per reported line).
ESC=""
esc() {
    local s="$1" i
    for ((i = 0; i < ${#_CTL_HEX[@]}; i++)); do
        s="${s//"${_CTL_BYTE[$i]}"/"${_CTL_REPL[$i]}"}"
    done
    ESC="$s"
}

# --- report buffer ---------------------------------------------------------
# The header names the error count, which is only known once every file has been
# scanned, so findings are buffered and flushed after the header.
BODY=""
WARNC=0
ERRC=0
SCANNED=0
TOOBIG=0
LABEL=""

add_line() { BODY+="$1"$'\n'; }

emit_details() {
    local total i=0 _a _b _len
    total="$(printf '%s\n' "$SCAN_RUNS" | grep -c . || true)"
    [[ "$total" =~ ^[0-9]+$ ]] || total=0
    while read -r _a _b _len; do
        [[ -z "${_len:-}" ]] && continue
        i=$((i + 1))
        [[ "$i" -le 5 ]] && add_line "  L${_a}-L${_b} (${_len} comment lines)"
    done <<< "$SCAN_RUNS"
    [[ "$total" -gt 5 ]] && add_line "  ... and $((total - 5)) more"
    return 0
}
