#!/bin/bash
# run-phase5-record.sh — Phase 5: record created issue(s) to WORKTREE_NOTES.md
# Usage: bash run-phase5-record.sh <verdict> <notes_path|auto> <title> [<manifest>]
#          [--input-file <path>] [--remove-manifest]
# `auto` resolves WORKTREE_NOTES.md from the git toplevel, and --input-file
# replaces the stdin pipe, so a prompt can issue this as one command (#2132).
# --remove-manifest (bulk-sub-of only) deletes a *-bulk-dispatch-*.tsv manifest
# after recording, unless a row fell back to the Phase 1 title (#3013).
# Stdin: Phase 4 dispatch stdout (URL lines) when --input-file is absent
# Exit:  0 always (non-fatal script — failures logged to stderr and skipped)
set -euo pipefail

VERDICT="${1:?verdict required}"
NOTES_PATH="${2:?notes_path required}"
TITLE="${3:?title required}"
MANIFEST="${4:-}"
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
shift $(( $# < 4 ? $# : 4 ))

INPUT_FILE=""
REMOVE_MANIFEST=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --input-file) INPUT_FILE="${2:?--input-file requires a value}"; shift 2 ;;
        --remove-manifest) REMOVE_MANIFEST=1; shift ;;
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
    MANIFEST_READABLE=0
    MANIFEST_ROWS=0
    if [[ -f "$MANIFEST" && -r "$MANIFEST" ]] && MANIFEST_ROWS="$(awk 'END { print NR }' "$MANIFEST")"; then
        MANIFEST_READABLE=1
    else
        echo "run-phase5-record.sh: warning: cannot read manifest '$MANIFEST'; every row falls back to the Phase 1 title (non-fatal)" >&2
    fi
    FALLBACK_COUNT=0
    APPEND_FAIL_COUNT=0
    row_index=0
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        N="$(echo "$url" | tr -d '\r' | grep -oE '[0-9]+$' || true)"
        if [[ -z "$N" ]]; then
            echo "run-phase5-record.sh: warning: could not extract issue number from URL '$url'; skipping (non-fatal)" >&2
            APPEND_FAIL_COUNT=$(( APPEND_FAIL_COUNT + 1 ))
            row_index=$(( row_index + 1 ))
            continue
        fi
        row_no=$(( row_index + 1 ))
        row_title=""
        if [[ "$MANIFEST_READABLE" -eq 0 ]]; then
            echo "run-phase5-record.sh: warning: issue #$N: manifest unreadable; using the Phase 1 title (non-fatal)" >&2
            FALLBACK_COUNT=$(( FALLBACK_COUNT + 1 ))
        elif [[ "$row_no" -gt "$MANIFEST_ROWS" ]]; then
            echo "run-phase5-record.sh: warning: issue #$N: manifest has no row $row_no; using the Phase 1 title (non-fatal)" >&2
            FALLBACK_COUNT=$(( FALLBACK_COUNT + 1 ))
        else
            row_title="$(awk -F'\t' -v row="$row_no" 'NR == row { print $1 }' "$MANIFEST" | tr -d '\r')" || row_title=""
            if [[ -z "$row_title" ]]; then
                echo "run-phase5-record.sh: warning: issue #$N: manifest row $row_no has an empty title; using the Phase 1 title (non-fatal)" >&2
                FALLBACK_COUNT=$(( FALLBACK_COUNT + 1 ))
            fi
        fi
        TITLE_FOR_ISSUE="${row_title:-$TITLE}"
        node "$SCRIPT_CHECKOUT_ROOT/bin/worktree-notes-append.js" \
            --notes-path "$NOTES_PATH" \
            --issue-number "$N" \
            --title "$TITLE_FOR_ISSUE" \
            --label type:task \
            --skip-if-main \
            || { echo "run-phase5-record.sh: warning: worktree-notes-append.js failed for issue #$N (non-fatal)" >&2; APPEND_FAIL_COUNT=$(( APPEND_FAIL_COUNT + 1 )); }
        row_index=$(( row_index + 1 ))
    done <<< "$DISPATCH_OUTPUT"
    if [[ "$MANIFEST_READABLE" -eq 1 && "$row_index" -lt "$MANIFEST_ROWS" ]]; then
        APPEND_FAIL_COUNT=$(( APPEND_FAIL_COUNT + MANIFEST_ROWS - row_index ))
    fi
    if [[ "$REMOVE_MANIFEST" -eq 1 ]]; then
        if [[ "$(basename -- "$MANIFEST")" != *-bulk-dispatch-*.tsv ]]; then
            echo "run-phase5-record.sh: warning: --remove-manifest ignored: '$MANIFEST' does not match *-bulk-dispatch-*.tsv (non-fatal)" >&2
        elif [[ "$FALLBACK_COUNT" -gt 0 ]]; then
            echo "run-phase5-record.sh: warning: manifest kept at '$MANIFEST': $FALLBACK_COUNT row(s) used the Phase 1 title; check their real titles there (non-fatal)" >&2
        elif [[ "$APPEND_FAIL_COUNT" -gt 0 ]]; then
            echo "run-phase5-record.sh: warning: manifest kept at '$MANIFEST': $APPEND_FAIL_COUNT row(s) failed to record; their titles are only in the manifest (non-fatal)" >&2
        elif [[ -e "$MANIFEST" ]] && ! rm -f -- "$MANIFEST"; then
            echo "run-phase5-record.sh: warning: could not remove manifest '$MANIFEST' (non-fatal)" >&2
        fi
    fi
else
    N="$(echo "$DISPATCH_OUTPUT" | tail -n 1 | tr -d '\r' | grep -oE '[0-9]+$' || true)"
    if [[ -z "$N" ]]; then
        echo "run-phase5-record.sh: warning: could not extract issue number from dispatch output (non-fatal)" >&2
        exit 0
    fi
    node "$SCRIPT_CHECKOUT_ROOT/bin/worktree-notes-append.js" \
        --notes-path "$NOTES_PATH" \
        --issue-number "$N" \
        --title "$TITLE" \
        --label type:task \
        --skip-if-main \
        || echo "run-phase5-record.sh: warning: worktree-notes-append.js failed for issue #$N (non-fatal)" >&2
fi

exit 0
