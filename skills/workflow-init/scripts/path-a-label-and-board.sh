#!/usr/bin/env bash
# workflow-init Path A2 — label all issues + ensure-board-card parity.
#
# Usage:
#   PLANS_DIR=... SESSION_ID=... AGENTS_CONFIG_DIR=... \
#     bash path-a-label-and-board.sh [--repo-map IDX:owner/repo ...] <primary-N> [related-N ...]
#
# --repo-map IDX:owner/repo  (repeatable) — per-issue repo routing. Index is
#   0-based across ALL issues (primary=idx0, related[k]=idx k+1).
#
# Behavior:
#   - For each related issue (positions 2..N): gh issue edit --add-label intent:clarified.
#     Label failure for any related issue is fail-closed (writes an abort marker, exit 1).
#     gh issue edit --add-label is idempotent — re-running /workflow-init is safe.
#   - For every issue (primary + related): ensure-board-card.sh (best-effort; warn-continue).
#     ensure-board-card.sh is itself idempotent — no-op when the card is already present.

set -uo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR must be set}"

if [ "$#" -lt 1 ]; then
    echo "[path-a-label-and-board] usage: [--repo-map IDX:owner/repo ...] <primary-N> [related-N ...]" >&2
    exit 2
fi

declare -A REPO_OF
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --repo-map)
            [ $# -lt 2 ] && { echo "Error: --repo-map requires a value" >&2; exit 2; }
            KEY="${2%%:*}"; VAL="${2#*:}"; REPO_OF["$KEY"]="$VAL"; shift 2
            ;;
        --repo-map=*)
            PAIR="${1#--repo-map=}"; KEY="${PAIR%%:*}"; VAL="${PAIR#*:}"; REPO_OF["$KEY"]="$VAL"; shift
            ;;
        --) shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done ;;
        -*) echo "[path-a-label-and-board] unknown option: $1" >&2; exit 2 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

if [ "${#POSITIONAL[@]}" -lt 1 ]; then
    echo "[path-a-label-and-board] usage: [--repo-map IDX:owner/repo ...] <primary-N> [related-N ...]" >&2
    exit 2
fi

PRIMARY="${POSITIONAL[0]}"
RELATED=("${POSITIONAL[@]:1}")

# Label related issues (index 1..N in the full list).
for k in "${!RELATED[@]}"; do
    N="${RELATED[$k]}"
    i=$((k + 1))
    if ! gh issue edit "$N" ${REPO_OF[$i]:+--repo "${REPO_OF[$i]}"} --add-label "intent:clarified"; then
        if [ -n "${PLANS_DIR:-}" ] && [ -n "${SESSION_ID:-}" ]; then
            MARKER="$PLANS_DIR/$SESSION_ID-workflow-init-aborted-pathA-multiN-label-failure.md"
            printf 'workflow-init Path A2 aborted: gh issue edit --add-label "intent:clarified" failed for #%s\n' "$N" > "$MARKER" 2>/dev/null || true
        fi
        echo "[workflow-init: gh issue edit --add-label intent:clarified failed for #$N — aborting]" >&2
        exit 1
    fi
done

# ensure-board-card for all issues (primary at idx 0, related at idx 1..N).
ALL_ISSUES=("$PRIMARY" "${RELATED[@]}")
for i in "${!ALL_ISSUES[@]}"; do
    N="${ALL_ISSUES[$i]}"
    if ! bash "$AGENTS_CONFIG_DIR/bin/github-issues/ensure-board-card.sh" ${REPO_OF[$i]:+--repo "${REPO_OF[$i]}"} "$N"; then
        echo "[workflow-init: ensure-board-card.sh failed for #$N (continuing)]" >&2
    fi
done

exit 0
