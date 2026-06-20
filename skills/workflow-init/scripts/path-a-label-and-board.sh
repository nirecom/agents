#!/usr/bin/env bash
# workflow-init Path A2 — label all issues + ensure-board-card parity.
#
# Usage:
#   PLANS_DIR=... SESSION_ID=... AGENTS_CONFIG_DIR=... \
#     bash path-a-label-and-board.sh <primary-N> [related-N ...]
#
# Behavior:
#   - For each related issue (positions 2..N): gh issue edit --add-label intent:clarified.
#     Label failure for any related issue is fail-closed (writes an abort marker, exit 1).
#     gh issue edit --add-label is idempotent — re-running /workflow-init is safe.
#   - For every issue (primary + related): ensure-board-card.sh (best-effort; warn-continue).
#     ensure-board-card.sh is itself idempotent — no-op when the card is already present.

set -uo pipefail

if [ "$#" -lt 1 ]; then
    echo "[path-a-label-and-board] usage: <primary-N> [related-N ...]" >&2
    exit 2
fi

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR must be set}"

PRIMARY="$1"
shift
RELATED=("$@")

for N in "${RELATED[@]}"; do
    if ! gh issue edit "$N" --add-label "intent:clarified"; then
        if [ -n "${PLANS_DIR:-}" ] && [ -n "${SESSION_ID:-}" ]; then
            MARKER_DIR="$PLANS_DIR/drafts"
            mkdir -p "$MARKER_DIR" 2>/dev/null || true
            MARKER="$MARKER_DIR/$SESSION_ID-workflow-init-aborted-pathA-multiN-label-failure.md"
            printf 'workflow-init Path A2 aborted: gh issue edit --add-label "intent:clarified" failed for #%s\n' "$N" > "$MARKER" 2>/dev/null || true
        fi
        echo "[workflow-init: gh issue edit --add-label intent:clarified failed for #$N — aborting]" >&2
        exit 1
    fi
done

for N in "$PRIMARY" "${RELATED[@]}"; do
    if ! bash "$AGENTS_CONFIG_DIR/bin/github-issues/ensure-board-card.sh" "$N"; then
        echo "[workflow-init: ensure-board-card.sh failed for #$N (continuing)]" >&2
    fi
done

exit 0
