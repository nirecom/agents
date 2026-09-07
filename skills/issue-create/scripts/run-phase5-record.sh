#!/bin/bash
# run-phase5-record.sh — Phase 5: record created issue(s) to WORKTREE_NOTES.md
# Usage: bash run-phase5-record.sh <verdict> <notes_path|auto> <title> [<manifest>]
#          [--input-file <path>]
# `auto` resolves WORKTREE_NOTES.md from the git toplevel, and --input-file
# replaces the stdin pipe, so a prompt can issue this as one command (#2132).
# Env:   AGENTS_CONFIG_DIR
# Stdin: Phase 4 dispatch stdout (URL lines) when --input-file is absent
# Exit:  0 always (non-fatal script — failures logged to stderr and skipped)
set -euo pipefail

VERDICT="${1:?verdict required}"
NOTES_PATH="${2:?notes_path required}"
TITLE="${3:?title required}"
MANIFEST="${4:-}"
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"
shift $(( $# < 4 ? $# : 4 ))

INPUT_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --input-file) INPUT_FILE="${2:?--input-file requires a value}"; shift 2 ;;
        *) echo "run-phase5-record.sh: unknown argument: $1" >&2; exit 0 ;;
    esac
done

if [[ "$NOTES_PATH" == "auto" ]]; then
    TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "$TOPLEVEL" ]]; then
        echo "run-phase5-record.sh: warning: cannot resolve git toplevel; skipping record (non-fatal)" >&2
        exit 0
    fi
    NOTES_PATH="$TOPLEVEL/WORKTREE_NOTES.md"
fi

if [[ -n "$INPUT_FILE" ]]; then
    DISPATCH_OUTPUT="$(cat -- "$INPUT_FILE")"
else
    DISPATCH_OUTPUT="$(cat)"
fi

if [[ "$VERDICT" == "bulk-sub-of" ]]; then
    if [[ -z "$MANIFEST" ]]; then
        echo "run-phase5-record.sh: warning: bulk-sub-of verdict requires manifest path; skipping record (non-fatal)" >&2
        exit 0
    fi
    row_index=0
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        N="$(echo "$url" | tr -d '\r' | grep -oE '[0-9]+$' || true)"
        if [[ -z "$N" ]]; then
            echo "run-phase5-record.sh: warning: could not extract issue number from URL '$url'; skipping (non-fatal)" >&2
            row_index=$(( row_index + 1 ))
            continue
        fi
        row_title="$(awk -F'\t' "NR==$(( row_index + 1 )) { print \$1 }" "$MANIFEST" || true)"
        TITLE_FOR_ISSUE="${row_title:-$TITLE}"
        node "$AGENTS_CONFIG_DIR/bin/worktree-notes-append.js" \
            --notes-path "$NOTES_PATH" \
            --issue-number "$N" \
            --title "$TITLE_FOR_ISSUE" \
            --label type:task \
            --skip-if-main \
            || echo "run-phase5-record.sh: warning: worktree-notes-append.js failed for issue #$N (non-fatal)" >&2
        row_index=$(( row_index + 1 ))
    done <<< "$DISPATCH_OUTPUT"
else
    N="$(echo "$DISPATCH_OUTPUT" | tail -n 1 | tr -d '\r' | grep -oE '[0-9]+$' || true)"
    if [[ -z "$N" ]]; then
        echo "run-phase5-record.sh: warning: could not extract issue number from dispatch output (non-fatal)" >&2
        exit 0
    fi
    node "$AGENTS_CONFIG_DIR/bin/worktree-notes-append.js" \
        --notes-path "$NOTES_PATH" \
        --issue-number "$N" \
        --title "$TITLE" \
        --label type:task \
        --skip-if-main \
        || echo "run-phase5-record.sh: warning: worktree-notes-append.js failed for issue #$N (non-fatal)" >&2
fi

exit 0
