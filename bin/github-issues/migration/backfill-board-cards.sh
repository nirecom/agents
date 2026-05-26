#!/usr/bin/env bash
# backfill-board-cards.sh — one-off Projects v2 board-card backfill.
#
# Delegates to ensure-board-card.sh for each issue number. Idempotent: safe to
# re-run; issues already on the board are no-ops.
#
# Usage:
#   backfill-board-cards.sh <N> [<N> ...]
#   echo -e "123\n456" | backfill-board-cards.sh
#   backfill-board-cards.sh --from-file <path>
#
# Comments (#-prefix) and blank lines from stdin / file are skipped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIMITIVE="$SCRIPT_DIR/../ensure-board-card.sh"

if [[ ! -x "$PRIMITIVE" ]]; then
    echo "error: ensure-board-card.sh not executable at $PRIMITIVE" >&2
    exit 2
fi

ISSUES=()
FROM_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-file)
            [[ $# -lt 2 ]] && { echo "error: --from-file requires a path" >&2; exit 2; }
            FROM_FILE="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,12p' "$0" >&2
            exit 0
            ;;
        --*)
            echo "error: unknown flag: $1" >&2
            exit 2
            ;;
        *)
            ISSUES+=("$1")
            shift
            ;;
    esac
done

collect_from_stream() {
    local stream="$1"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        # Strip leading/trailing whitespace.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue
        # Strip leading '#' from issue references.
        line="${line#\#}"
        ISSUES+=("$line")
    done < "$stream"
}

if [[ -n "$FROM_FILE" ]]; then
    [[ -r "$FROM_FILE" ]] || { echo "error: cannot read $FROM_FILE" >&2; exit 2; }
    collect_from_stream "$FROM_FILE"
elif [[ ${#ISSUES[@]} -eq 0 ]] && [[ ! -t 0 ]]; then
    # No positional args + stdin is a pipe → read from stdin.
    collect_from_stream /dev/stdin
fi

if [[ ${#ISSUES[@]} -eq 0 ]]; then
    echo "error: no issue numbers provided (positional args, --from-file, or stdin)" >&2
    exit 2
fi

count_total=0
count_ok=0
count_skipped=0
count_failed=0

for raw in "${ISSUES[@]}"; do
    n="${raw#\#}"
    count_total=$((count_total + 1))
    if [[ ! "$n" =~ ^[0-9]+$ ]]; then
        echo "[backfill] skip non-integer entry: '$raw'" >&2
        count_skipped=$((count_skipped + 1))
        continue
    fi
    if bash "$PRIMITIVE" "$n"; then
        echo "[backfill] OK #$n"
        count_ok=$((count_ok + 1))
    else
        echo "[backfill] FAIL #$n" >&2
        count_failed=$((count_failed + 1))
    fi
done

echo "[backfill] Done: $count_ok / $count_total issues (skipped: $count_skipped, failed: $count_failed)"
exit 0
