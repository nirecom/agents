#!/usr/bin/env bash
# bin/check-false-green.sh
# T1-F: false-green test detection.
# Detects patterns where want and got of assert_eq are the same literal (HARD).
# Reports bare pass near line start as WARN (SOFT).
#
# Usage: check-false-green.sh <test-file> [test-file ...]
#
# Exit codes:
#   0 = no false-green patterns (WARN-only is still 0)
#   1 = false-green pattern detected (FALSE-GREEN)
#   2 = usage error

set -uo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: check-false-green.sh <test-file> [test-file ...]" >&2
    exit 2
fi

VIOLATIONS=0

for file in "$@"; do
    if [[ ! -f "$file" ]]; then
        echo "ERROR: file not found: $file" >&2
        continue
    fi

    # HARD: detect assert_eq with same-literal both sides (double quotes)
    # Pattern: assert_eq <name> "x" "x"  where both quoted strings are identical
    # Uses PCRE backreference \1 to match repeated literal
    if grep -P '' /dev/null 2>/dev/null; then
        # PCRE available
        dq_hits="$(grep -nP 'assert_eq\s+\S+\s+"([^"]*)"\s+"\1"' "$file" 2>/dev/null | grep -v 'assert_eq()' || true)"
        if [[ -n "$dq_hits" ]]; then
            echo "$dq_hits"
            echo "FALSE-GREEN: $file (same-literal assert_eq with double quotes)" >&2
            VIOLATIONS=$((VIOLATIONS + 1))
        fi

        # Single-quote variant
        sq_hits="$(grep -nP "assert_eq\s+\S+\s+'([^']*)'\s+'\1'" "$file" 2>/dev/null | grep -v 'assert_eq()' || true)"
        if [[ -n "$sq_hits" ]]; then
            echo "$sq_hits"
            echo "FALSE-GREEN: $file (same-literal assert_eq with single quotes)" >&2
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    else
        # PCRE not available — use awk for double-quote detection
        awk_result=0
        awk_hits="$(awk '
            /assert_eq/ {
                line = $0
                # Try to extract the two quoted arguments after the name argument
                if (match(line, /assert_eq[[:space:]]+[^[:space:]]+[[:space:]]+"([^"]+)"[[:space:]]+"([^"]+)"/, arr)) {
                    if (arr[1] == arr[2]) {
                        print NR": "line
                        found = 1
                    }
                }
            }
            END { exit (found ? 1 : 0) }
        ' "$file" 2>/dev/null)" || awk_result=$?

        if [[ $awk_result -ne 0 ]]; then
            echo "$awk_hits"
            echo "FALSE-GREEN: $file (same-literal assert_eq detected via awk)" >&2
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    # SOFT: bare 'pass' at start of line (within 2 spaces indent) — may indicate unchecked pass
    bare_pass="$(grep -n '^\s\{0,2\}pass\b' "$file" 2>/dev/null | grep -v 'pass()' || true)"
    if [[ -n "$bare_pass" ]]; then
        echo "$bare_pass"
        echo "WARN: $file (bare 'pass' detected — may indicate unchecked pass call)" >&2
    fi
done

if [[ $VIOLATIONS -gt 0 ]]; then
    exit 1
fi
exit 0
