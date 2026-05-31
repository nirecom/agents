#!/usr/bin/env bash
# bin/lib/github-contents-validate.sh
#
# Validates a staged content file before GitHub Contents/Git Data API PUT.
#
# Usage:
#   bash bin/lib/github-contents-validate.sh \
#       --path <repo-relative-path> \
#       --file <abs-local-path> \
#       --commit-subject <commit-subject>
#
# Kind (history vs changelog) is inferred from --path:
#   paths containing "history" → history; others → changelog.
#
# Exit codes:
#   0  validation passed
#   2  validation failed (detail on stderr)
#   3  usage error
#
# Checks performed:
#   (a) content file is non-empty
#   (b) line-count gate (history: 1..800; changelog: >=1)
#   (c) commit subject matches docs(history|changelog): record [issue|PR] #<N>
#   (d) content file ends with a trailing newline (0x0a)
#   (e) when PLAN_LANG=english, warn (non-fatal) if non-ASCII ratio > 10%
set -euo pipefail

PATH_ARG=""
FILE=""
COMMIT_SUBJECT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)           PATH_ARG="${2:-}";        shift 2 ;;
        --file)           FILE="${2:-}";             shift 2 ;;
        --commit-subject) COMMIT_SUBJECT="${2:-}";   shift 2 ;;
        *) echo "github-contents-validate: unknown argument: $1" >&2; exit 3 ;;
    esac
done

if [[ -z "$PATH_ARG" || -z "$FILE" || -z "$COMMIT_SUBJECT" ]]; then
    echo "github-contents-validate: --path, --file, --commit-subject are required" >&2
    exit 3
fi

# Infer kind from path
if [[ "$PATH_ARG" == *history* ]]; then
    KIND=history
else
    KIND=changelog
fi

# Check (a): non-empty
if [[ ! -s "$FILE" ]]; then
    echo "github-contents-validate: content file is missing or empty: $FILE" >&2
    exit 2
fi

# Check (b): line count
LINES=$(wc -l < "$FILE")
if [[ "$KIND" == "history" ]]; then
    if (( LINES < 1 || LINES > 800 )); then
        echo "github-contents-validate: history line count out of range (1..800): $LINES" >&2
        exit 2
    fi
else
    if (( LINES < 1 )); then
        echo "github-contents-validate: changelog line count must be >= 1: $LINES" >&2
        exit 2
    fi
fi

# Check (c): subject regex
if ! printf '%s' "$COMMIT_SUBJECT" | grep -qE '^docs\((history|changelog)\): (record|record issue|record PR) #[0-9]+$'; then
    echo "github-contents-validate: commit subject does not match expected pattern: $COMMIT_SUBJECT" >&2
    echo "  Expected: docs(history|changelog): record [issue|PR] #<N>" >&2
    exit 2
fi

# Check (d): trailing newline
LAST_BYTE=$(tail -c 1 "$FILE" | od -A n -t x1 | tr -d ' \n')
if [[ "$LAST_BYTE" != "0a" ]]; then
    echo "github-contents-validate: content file does not end with a trailing newline" >&2
    exit 2
fi

# Check (e): PLAN_LANG=english warning (non-fatal)
PLAN_LANG_VAL="${PLAN_LANG:-}"
if [[ -z "$PLAN_LANG_VAL" ]] && [[ -n "${AGENTS_CONFIG_DIR:-}" ]] && [[ -r "$AGENTS_CONFIG_DIR/.env" ]]; then
    PLAN_LANG_VAL=$(grep -E '^[[:space:]]*PLAN_LANG[[:space:]]*=' "$AGENTS_CONFIG_DIR/.env" 2>/dev/null \
        | tail -n 1 | sed -E 's/^[[:space:]]*PLAN_LANG[[:space:]]*=[[:space:]]*//; s/^["'\'']//; s/["'\'']$//' || true)
fi
if [[ "$(printf '%s' "$PLAN_LANG_VAL" | tr '[:upper:]' '[:lower:]')" == "english" ]]; then
    TOTAL=$(wc -c < "$FILE")
    NON_ASCII=$(LC_ALL=C tr -d '\000-\177' < "$FILE" | wc -c)
    if (( TOTAL > 0 )); then
        # ratio = NON_ASCII * 100 / TOTAL
        RATIO=$(( NON_ASCII * 100 / TOTAL ))
        if (( RATIO > 10 )); then
            echo "github-contents-validate: warning — PLAN_LANG=english but non-ASCII ratio is ${RATIO}% (> 10%)" >&2
        fi
    fi
fi

exit 0
