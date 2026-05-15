#!/bin/bash
# backfill-commit-comments.sh [--dry-run] [--canary]
#
# Retroactive migration: for each closed GitHub issue that lacks an
# `<!-- issue-close-sentinel: appended -->` comment, post J-1 + J-2 comments
# to match the format produced by `/issue-close` in real time.
#
# 3-tier hash discovery:
#   Tier 1 — history.md / history/*.md heading bracket hex (7-40 chars)
#   Tier 2 — git log --grep "#N([^0-9]|$)" boundary-safe search
#   Tier 3 — no-hash (J-2 only, no J-1)
#
# --canary: post at most 1 issue per class (max 3 total). Review posted
#           comments on GitHub, then run without --canary for the full batch.
#
# Uses `gh --jq` (built into the gh CLI) — no external jq dependency.
#
# Note: -e (errexit) is intentionally omitted so that `grep` no-match exit
# does not abort the script. Failing commands are guarded individually.

set -uo pipefail

DRY_RUN=0
CANARY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --canary)  CANARY=1; shift ;;
        *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -z "${AGENTS_CONFIG_DIR:-}" ]; then
    echo "Error: AGENTS_CONFIG_DIR not set" >&2
    exit 1
fi

HISTORY_FILE="${AGENTS_CONFIG_DIR}/docs/history.md"
HISTORY_DIR="${AGENTS_CONFIG_DIR}/docs/history"

# Tier 1: extract 7-40 hex chars from the last bracket group in a history.md heading.
discover_hash_from_history() {
    local n="$1" entry hash
    entry=""
    [ -f "$HISTORY_FILE" ] && \
        entry=$(grep -E "^### .*#${n}[,)]|^### #${n}: " "$HISTORY_FILE" 2>/dev/null | head -n 1 || true)
    if [ -z "$entry" ] && [ -d "$HISTORY_DIR" ] && ls "$HISTORY_DIR"/*.md >/dev/null 2>&1; then
        entry=$(grep -hE "^### .*#${n}[,)]|^### #${n}: " "$HISTORY_DIR"/*.md 2>/dev/null | head -n 1 || true)
    fi
    [ -z "$entry" ] && return 1
    hash=$(printf '%s' "$entry" | grep -oE '\([^)]*\)' | tail -n 1 \
        | grep -oE '[0-9a-f]{7,40}' | head -n 1 || true)
    [ -z "$hash" ] && return 2
    printf '%s' "$hash"
}

# Tier 2: boundary-safe git log search. -E + ([^0-9]|$) prevents #42 matching #420.
discover_hash_from_gitlog() {
    local n="$1" line hash
    line=$(git -C "$AGENTS_CONFIG_DIR" log --all --oneline -E \
        --grep="#${n}([^0-9]|\$)" 2>/dev/null | head -n 1 || true)
    [ -z "$line" ] && return 0
    hash=$(printf '%s' "$line" | awk '{print $1}')
    printf '%s' "$hash" | grep -qE '^[0-9a-f]{7,40}$' || return 0
    printf '%s' "$hash"
}

# Sets CLASS (hash-from-history | hash-from-gitlog | no-hash) and HASH globals.
classify_issue() {
    local n="$1"
    HASH=""
    if HASH=$(discover_hash_from_history "$n") && [ -n "$HASH" ]; then
        CLASS="hash-from-history"; return
    fi
    if HASH=$(discover_hash_from_gitlog "$n") && [ -n "$HASH" ]; then
        CLASS="hash-from-gitlog"; return
    fi
    CLASS="no-hash"; HASH=""
}

# J-1 idempotency: check for existing <!-- resolved-by: HASH --> comment.
has_resolved_by() {
    local n="$1" hash="$2" hit
    hit=$(gh issue view "$n" --json comments \
        --jq "[.comments[].body | select(test(\"^<!-- resolved-by: ${hash} -->\"))] | first // \"\"" \
        2>/dev/null) || hit=""
    [ -n "$hit" ]
}

# J-2 idempotency: check for existing appended sentinel.
has_appended_sentinel() {
    local n="$1" hit
    hit=$(gh issue view "$n" --json comments \
        --jq '[.comments[].body | select(test("^<!-- issue-close-sentinel: appended"))] | first // ""' \
        2>/dev/null) || hit=""
    [ -n "$hit" ]
}

POSTED=0
SKIPPED=0
# Canary flags: bash 3.2 compatible scalars instead of declare -A.
CANARY_DONE_HIST=0
CANARY_DONE_GITLOG=0
CANARY_DONE_NOHASH=0

ALL_NUMBERS=$(gh issue list --state closed --limit 1000 \
    --json number --jq '.[].number' 2>/dev/null || true)

while IFS= read -r N; do
    [ -z "$N" ] && continue

    if has_appended_sentinel "$N"; then
        echo "[skip] #${N} already has appended sentinel"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    classify_issue "$N"

    if [ "$CANARY" -eq 1 ]; then
        case "$CLASS" in
          hash-from-history)
            [ "$CANARY_DONE_HIST"   -eq 1 ] && { echo "[canary-skip class=${CLASS}] #${N}"; SKIPPED=$((SKIPPED+1)); continue; } ;;
          hash-from-gitlog)
            [ "$CANARY_DONE_GITLOG" -eq 1 ] && { echo "[canary-skip class=${CLASS}] #${N}"; SKIPPED=$((SKIPPED+1)); continue; } ;;
          no-hash)
            [ "$CANARY_DONE_NOHASH" -eq 1 ] && { echo "[canary-skip class=${CLASS}] #${N}"; SKIPPED=$((SKIPPED+1)); continue; } ;;
        esac
    fi

    case "$CLASS" in
      hash-from-history) SENTINEL_BODY="<!-- issue-close-sentinel: appended (resolved-by: backfill, commit=${HASH}) -->" ;;
      hash-from-gitlog)  SENTINEL_BODY="<!-- issue-close-sentinel: appended (resolved-by: backfill-gitlog, commit=${HASH}) -->" ;;
      no-hash)           SENTINEL_BODY="<!-- issue-close-sentinel: appended (resolved-by: backfill-no-hash) -->" ;;
    esac

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run class=${CLASS}] #${N} hash=${HASH:-none}"
        POSTED=$((POSTED + 1))
        case "$CLASS" in
          hash-from-history) CANARY_DONE_HIST=1 ;;
          hash-from-gitlog)  CANARY_DONE_GITLOG=1 ;;
          no-hash)           CANARY_DONE_NOHASH=1 ;;
        esac
        continue
    fi

    if [ -n "$HASH" ]; then
        if has_resolved_by "$N" "$HASH"; then
            echo "[skip-j1] #${N} resolved-by:${HASH} already present"
        else
            echo "[post-j1 class=${CLASS}] #${N} commit=${HASH}"
            ISSUE_CLOSE_SKILL=1 gh issue comment "$N" --body "<!-- resolved-by: ${HASH} -->
Resolved by commit \`${HASH}\`."
        fi
    fi

    echo "[post-j2 class=${CLASS}] #${N}"
    ISSUE_CLOSE_SKILL=1 gh issue comment "$N" --body "$SENTINEL_BODY"

    POSTED=$((POSTED + 1))
    case "$CLASS" in
      hash-from-history) CANARY_DONE_HIST=1 ;;
      hash-from-gitlog)  CANARY_DONE_GITLOG=1 ;;
      no-hash)           CANARY_DONE_NOHASH=1 ;;
    esac
done <<< "$ALL_NUMBERS"

if [ "$DRY_RUN" -eq 1 ]; then
    echo ""
    echo "=== Classification summary ==="
    echo "Run without --dry-run to execute."
fi
echo "Backfilled: ${POSTED}, Skipped: ${SKIPPED}"
