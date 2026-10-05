#!/usr/bin/env bash
# workflow-init Path A2 — label all issues + ensure-board-card parity (skills/workflow-init/SKILL.md A2).
# Usage: SESSION_ID=... AGENTS_CONFIG_DIR=... bash path-a-label-and-board.sh [--repo-map IDX:owner/repo ...] <first-N> [siblings-N ...]
# --repo-map index is 0-based across ALL issues (first-N=idx0, siblings[k]=idx k+1).
# Sibling label failure is fail-closed (abort marker in the session control dir, exit 1);
# ensure-board-card.sh is best-effort. Both steps are idempotent, so re-running is safe.

set -uo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR must be set}"

if [ "$#" -lt 1 ]; then
    echo "[path-a-label-and-board] usage: [--repo-map IDX:owner/repo ...] <first-N> [siblings-N ...]" >&2
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
    echo "[path-a-label-and-board] usage: [--repo-map IDX:owner/repo ...] <first-N> [siblings-N ...]" >&2
    exit 2
fi

FIRST_N="${POSITIONAL[0]}"
SIBLINGS=("${POSITIONAL[@]:1}")

# Label sibling issues (index 1..N in the full list).
for k in "${!SIBLINGS[@]}"; do
    N="${SIBLINGS[$k]}"
    i=$((k + 1))
    if ! gh issue edit "$N" ${REPO_OF[$i]:+--repo "${REPO_OF[$i]}"} --add-label "intent:clarified" >/dev/null 2>&1; then
        if [ -n "${SESSION_ID:-}" ] && MARKER="$(node "$AGENTS_CONFIG_DIR/bin/workflow-control-dir" --session "$SESSION_ID" --file workflow-init-aborted-pathA-multiN-label-failure.md --for-write 2>/dev/null)"; then
            printf 'workflow-init Path A2 aborted: gh issue edit --add-label "intent:clarified" failed for #%s\n' "$N" > "$MARKER" 2>/dev/null || true
        fi
        echo "[workflow-init: gh issue edit --add-label intent:clarified failed for #$N — aborting]" >&2
        exit 1
    fi
done

# ensure-board-card for all issues (first-N at idx 0, siblings at idx 1..N).
ALL_ISSUES=("$FIRST_N" "${SIBLINGS[@]}")
for i in "${!ALL_ISSUES[@]}"; do
    N="${ALL_ISSUES[$i]}"
    if ! bash "$AGENTS_CONFIG_DIR/bin/github-issues/ensure-board-card.sh" ${REPO_OF[$i]:+--repo "${REPO_OF[$i]}"} "$N"; then
        echo "[workflow-init: ensure-board-card.sh failed for #$N (continuing)]" >&2
    fi
done

exit 0
