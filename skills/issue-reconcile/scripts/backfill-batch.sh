#!/bin/bash
# Batch-backfill docs/history.md for a list of closed issues.
#
# Usage:
#   backfill-batch.sh --repo-dir <abs-path> --numbers-file <path> [--dry-run]
#
# --repo-dir      linked worktree checkout whose docs/history.md is written
# --numbers-file  one issue number per line (blank lines and '#' comments ignored)
# --dry-run       resolve and report only; no writes
#
# Each issue is appended via issue-to-history.sh with --allow-backdate (entries
# are older than the tail) and --no-auto-rotate (rotating once per append would
# churn the archive). The stream is sorted and rotated once after the loop.
#
# Writes <repo-dir>/.backfill-appended.txt listing the issues that were appended,
# for the caller's sentinel-comment step. Exits non-zero if any issue failed.

set -uo pipefail

REPO_DIR=""
NUMBERS_FILE=""
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --repo-dir) REPO_DIR="${2:-}"; shift 2 ;;
        --numbers-file) NUMBERS_FILE="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$REPO_DIR" ] || [ -z "$NUMBERS_FILE" ]; then
    echo "Usage: $0 --repo-dir <abs-path> --numbers-file <path> [--dry-run]" >&2
    exit 1
fi

if [ -z "${AGENTS_CONFIG_DIR:-}" ]; then
    echo "Error: AGENTS_CONFIG_DIR is not set." >&2
    exit 1
fi

HISTORY="$REPO_DIR/docs/history.md"
if [ ! -f "$HISTORY" ]; then
    echo "Error: not found: $HISTORY" >&2
    exit 1
fi
if [ ! -f "$NUMBERS_FILE" ]; then
    echo "Error: not found: $NUMBERS_FILE" >&2
    exit 1
fi

NUMS=$(sed 's/#.*//' "$NUMBERS_FILE" | tr -s '[:space:]' '\n' | grep -E '^[0-9]+$')
if [ -z "$NUMS" ]; then
    echo "Error: no issue numbers in $NUMBERS_FILE" >&2
    exit 1
fi

TOTAL=$(printf '%s\n' "$NUMS" | wc -l | tr -d ' ')
echo "Backfilling $TOTAL issue(s) into $HISTORY"

if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "$NUMS" | tr '\n' ' '
    echo
    echo "DRY_RUN: no writes performed"
    exit 0
fi

APPENDED_FILE="$REPO_DIR/.backfill-appended.txt"
: > "$APPENDED_FILE"
FAILED=""
OK=0

for N in $NUMS; do
    if bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-to-history.sh" "$N" \
        --target "$HISTORY" --allow-backdate --no-auto-rotate; then
        echo "$N" >> "$APPENDED_FILE"
        OK=$((OK + 1))
    else
        echo "FAILED: #$N" >&2
        FAILED="$FAILED $N"
    fi
done

# Sort once: doc-append re-sorts pre-existing entries but writes each new entry
# at the tail, so the stream is out of order until this runs.
if ! (cd "$AGENTS_CONFIG_DIR" && uv run bin/sort-history.py "$HISTORY"); then
    echo "Error: sort-history.py failed" >&2
    exit 1
fi

# Rotate once, with the same thresholds doc-append's auto-rotation would use.
if ! (cd "$AGENTS_CONFIG_DIR" && uv run bin/doc-rotate.py "$HISTORY" --threshold-warn 500 --floor 20); then
    echo "Error: doc-rotate.py failed" >&2
    exit 1
fi

echo "Appended: $OK / $TOTAL"
if [ -n "$FAILED" ]; then
    echo "Failed:$FAILED" >&2
    exit 1
fi
