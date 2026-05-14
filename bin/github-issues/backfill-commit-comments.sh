#!/bin/bash
# backfill-commit-comments.sh [--dry-run]
#
# Retroactive migration: for each closed GitHub issue that lacks an
# `<!-- issue-close-sentinel: appended -->` comment, post one. When a matching
# `history.md` entry is found, include the resolved commit hash in the body.
#
# One-shot helper for the dual-write decommission (issue #222). After all
# legacy closed issues have been backfilled, this script should not need to
# run again — `/issue-close` posts the sentinel in real time.
#
# Uses `gh --jq` (built into the gh CLI) — no external jq dependency.
#
# Note: -e (errexit) is intentionally omitted so that a `grep` no-match exit
# does not abort the script. Failing commands are guarded individually.

set -uo pipefail

DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -z "${AGENTS_CONFIG_DIR:-}" ]; then
    echo "Error: AGENTS_CONFIG_DIR not set" >&2
    exit 1
fi

HISTORY_FILE="${AGENTS_CONFIG_DIR}/docs/history.md"
HISTORY_DIR="${AGENTS_CONFIG_DIR}/docs/history"

POSTED=0
SKIPPED=0

# Process substitution keeps POSTED/SKIPPED in the parent shell.
while IFS= read -r N; do
    [ -z "$N" ] && continue

    HAS_SENTINEL=$(gh issue view "$N" --json comments \
        --jq '[.comments[].body | select(test("^<!-- issue-close-sentinel: appended"))] | first // ""' \
        2>/dev/null) || HAS_SENTINEL=""

    if [ -n "$HAS_SENTINEL" ]; then
        echo "[skip] #${N} already has appended sentinel"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    ENTRY_LINE=""
    if [ -f "$HISTORY_FILE" ]; then
        ENTRY_LINE=$(grep -E "^### .*#${N}[,)]|^### #${N}: " "$HISTORY_FILE" 2>/dev/null | head -n 1 || true)
    fi
    if [ -z "$ENTRY_LINE" ] && [ -d "$HISTORY_DIR" ]; then
        if ls "$HISTORY_DIR"/*.md >/dev/null 2>&1; then
            ENTRY_LINE=$(grep -hE "^### .*#${N}[,)]|^### #${N}: " "$HISTORY_DIR"/*.md 2>/dev/null | head -n 1 || true)
        fi
    fi

    if [ -z "$ENTRY_LINE" ]; then
        echo "[warn] #${N} not found in history.md — skip"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    HASH=$(printf '%s' "$ENTRY_LINE" \
        | grep -oE '\([^)]*\)' | tail -n 1 \
        | grep -oE '[0-9a-f]{7,40}' | head -n 1 || true)

    HASH_SUFFIX=""
    [ -n "$HASH" ] && HASH_SUFFIX=", commit=${HASH}"

    BODY="<!-- issue-close-sentinel: appended (resolved-by: backfill${HASH_SUFFIX}) -->"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] #${N} would post sentinel${HASH_SUFFIX}"
    else
        echo "[post] #${N} sentinel${HASH_SUFFIX}"
        ISSUE_CLOSE_SKILL=1 gh issue comment "$N" --body "$BODY"
    fi
    POSTED=$((POSTED + 1))
done < <(gh issue list --state closed --limit 1000 --paginate --json number --jq '.[].number' 2>/dev/null || true)

echo "Backfilled: ${POSTED}, Skipped: ${SKIPPED}"
