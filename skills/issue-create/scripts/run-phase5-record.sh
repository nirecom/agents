#!/bin/bash
# run-phase5-record.sh — Phase 5: record created issue(s) to WORKTREE_NOTES.md
# Usage: <phase4-stdout> | bash run-phase5-record.sh <verdict> <notes_path> <title> [<manifest>]
# Env:   AGENTS_CONFIG_DIR
# Stdin: Phase 4 dispatch stdout (URL lines)
# Exit:  0 always (non-fatal script — failures logged to stderr and skipped)
set -euo pipefail

VERDICT="${1:?verdict required}"
NOTES_PATH="${2:?notes_path required}"
TITLE="${3:?title required}"
MANIFEST="${4:-}"
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"

DISPATCH_OUTPUT="$(cat)"

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
