#!/bin/bash
# STANDALONE TOOL — not invoked by any skill or workflow routing.
# Use manually for /issue-reconcile backfill or out-of-band history repair.
# Normal close-path history.md writes are owned by /worktree-end Step WE-20
# (compose-doc-append-entry reading WORKTREE_NOTES.md ## History Notes). #690
#
# Convert a (typically closed) GitHub issue into a docs/history.md entry.
#
# Usage:
#   bin/github-issues/issue-to-history.sh <issue-number> [--commit <hash>]
#       [--history-notes-file <path>] [--target <abs-path>]
#       [--non-github-mode --title <title> --body-file <path> --closed-date <YYYY-MM-DD>]
#
# When --target <abs-path> is provided, doc-append writes to that path instead
# of docs/history.md. Used by step-e.sh to append to a staging file fetched
# from the GitHub Contents API (see bin/lib/github-contents-write.sh).
#
# Requires AGENTS_CONFIG_DIR (the docs/ root). The script cd's there before
# writing so consumer repos can pass their own value to target the right
# history.md.
#
# Idempotent: if `#<N>:` already appears in docs/history.md or docs/history/,
# exits 0 without re-appending. (GitHub mode only — non-github-mode skips.)
#
# Environment variables:
#   ISSUE_CLOSE_HISTORY_NOTES_NONINTERACTIVE=1
#       CI-only override: when set, /issue-close-finalize Step E.1 skips the
#       AskUserQuestion prompt for inline History Notes. NOT a user-facing
#       configuration — do not add to .env.example. Set inline by CI runners
#       only.

set -uo pipefail

# --- Argument parsing ---
if [ $# -lt 1 ] && [ -z "${DRY_RUN:-}" ]; then
    echo "Usage: $0 <issue-number> [--commit <hash>] [--history-notes-file <path>] [--target <abs-path>] [--non-github-mode --title <t> --body-file <f> --closed-date <d>]" >&2
    exit 1
fi

if [ $# -ge 1 ]; then
    ISSUE_NUM="$1"
    shift
else
    ISSUE_NUM="${ISSUE_NUMBER:-0}"
fi

# Pure digits only — guards against shell injection via positional arg.
if ! printf '%s' "$ISSUE_NUM" | grep -qE '^[0-9]+$'; then
    echo "Error: issue number must be digits only, got: $ISSUE_NUM" >&2
    exit 1
fi

COMMIT=""
HISTORY_NOTES_FILE=""
NON_GITHUB_MODE=0
NG_TITLE=""
NG_BODY_FILE=""
NG_CLOSED_DATE=""
TARGET=""

while [ $# -gt 0 ]; do
    case "$1" in
        --commit)
            COMMIT="${2:-}"
            if [ -n "$COMMIT" ] && ! printf '%s' "$COMMIT" | grep -qE '^[0-9a-fA-F]{7,40}$'; then
                echo "Error: --commit must be a 7-40 char hex hash, got: $COMMIT" >&2
                exit 1
            fi
            shift 2
            ;;
        --history-notes-file)
            HISTORY_NOTES_FILE="${2:-}"
            shift 2
            ;;
        --non-github-mode)
            NON_GITHUB_MODE=1
            shift
            ;;
        --title)
            NG_TITLE="${2:-}"
            shift 2
            ;;
        --body-file)
            NG_BODY_FILE="${2:-}"
            shift 2
            ;;
        --closed-date)
            NG_CLOSED_DATE="${2:-}"
            shift 2
            ;;
        --target)
            TARGET="${2:-}"
            shift 2
            ;;
        *) shift ;;
    esac
done

# --- Environment check ---
if [ -z "${DRY_RUN:-}" ] && [ -z "${AGENTS_CONFIG_DIR:-}" ]; then
    echo "Error: AGENTS_CONFIG_DIR is not set. /issue-close-stage and /issue-close-finalize must be run from a session that has it configured." >&2
    exit 1
fi

if [ -z "${DRY_RUN:-}" ]; then
  cd "$AGENTS_CONFIG_DIR" || { echo "Error: failed to cd into AGENTS_CONFIG_DIR=$AGENTS_CONFIG_DIR" >&2; exit 1; }
fi

HISTORY_FILE="docs/history.md"
HISTORY_DIR="docs/history"

# --- DRY_RUN mode: use env-provided fields, skip gh + doc-append (test/smoke use only) ---
if [ -n "${DRY_RUN:-}" ]; then
    BODY="${ISSUE_BODY:-}"
    TITLE="${ISSUE_TITLE:-smoke}"
    CATEGORY="${ISSUE_CATEGORY:-FEATURE}"
    CLOSED_DATE="$(date +%Y-%m-%d)"
elif [ "$NON_GITHUB_MODE" -eq 1 ]; then
    # Non-GitHub mode: caller supplies title/body/date directly. Idempotency
    # check is skipped (issue may not exist on GitHub at all).
    TITLE="${NG_TITLE:-issue #${ISSUE_NUM}}"
    if [ -n "$NG_BODY_FILE" ] && [ -f "$NG_BODY_FILE" ]; then
        BODY="$(cat "$NG_BODY_FILE")"
    else
        BODY=""
    fi
    LABELS=""
    CATEGORY="FEATURE"
    if [ -n "$NG_CLOSED_DATE" ] && printf '%s' "$NG_CLOSED_DATE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
        CLOSED_DATE="$NG_CLOSED_DATE"
    else
        CLOSED_DATE="$(date +%Y-%m-%d)"
    fi
else

# --- Idempotency: skip if `### #N:` heading already present in history.md or rotated archive ---
# Anchor on `### ` prefix to avoid false-positive matches against in-body references
# like "follow-up from #42:" or "see also #42: ...".
GREP_BIN="$(command -v ggrep || echo grep)"
if LC_ALL=C.UTF-8 "$GREP_BIN" -rPq "(^### #${ISSUE_NUM}\b)|(^### [^(]+ \([^)]+#${ISSUE_NUM}\b[^)]*\))|(^### [^\n]*#${ISSUE_NUM}\b[^\n]*\([0-9]{4}-)" "$HISTORY_FILE" "$HISTORY_DIR" 2>/dev/null; then
    echo "Already in history (entry for #${ISSUE_NUM} exists). Skipping append."
    exit 0
fi

# --- Fetch issue data ---
if ! ISSUE_JSON=$(gh issue view "$ISSUE_NUM" --json number,title,body,closedAt,labels 2>/dev/null); then
    echo "Error: failed to fetch issue #$ISSUE_NUM from GitHub" >&2
    exit 1
fi
if [ -z "$ISSUE_JSON" ]; then
    echo "Error: empty response for issue #$ISSUE_NUM" >&2
    exit 1
fi

if ! command -v node >/dev/null 2>&1; then
    echo "Error: node not found (required for parsing gh output)" >&2
    exit 1
fi

# Extract fields from $ISSUE_JSON via a single node call. The expressions are
# passed via env vars (FIELD_*) so the script body is a literal, not interpolated
# with $1 — removes the shell-interpolation surface that a future caller might
# misuse.
PARSED=$(printf '%s' "$ISSUE_JSON" | node -e '
    let d = "";
    process.stdin.on("data", c => d += c);
    process.stdin.on("end", () => {
        try {
            const j = JSON.parse(d);
            // Use a sentinel separator unlikely to appear in issue content.
            const SEP = "\x1e";  // ASCII Record Separator
            process.stdout.write(
                String(j.title || "") + SEP +
                String(j.body || "") + SEP +
                (j.labels || []).map(l => l.name).join(",") + SEP +
            String(j.closedAt || "")
            );
        } catch (e) { process.exit(1); }
    });
')
if [ $? -ne 0 ] || [ -z "$PARSED" ]; then
    echo "Error: failed to parse issue JSON" >&2
    exit 1
fi
# Split on RS (ASCII 0x1E).
TITLE=$(printf '%s' "$PARSED" | awk -v RS=$'\x1e' 'NR==1{print}')
BODY=$(printf '%s' "$PARSED" | awk -v RS=$'\x1e' 'NR==2{print}')
LABELS=$(printf '%s' "$PARSED" | awk -v RS=$'\x1e' 'NR==3{print}')
CLOSED_AT=$(printf '%s' "$PARSED" | awk -v RS=$'\x1e' 'NR==4{print}')

# --- Resolve entry date: closedAt (YYYY-MM-DD), else today ---
if [ -n "$CLOSED_AT" ]; then
    CLOSED_DATE="${CLOSED_AT%%T*}"
else
    CLOSED_DATE="$(date +%Y-%m-%d)"
fi
if ! printf '%s' "$CLOSED_DATE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    CLOSED_DATE="$(date +%Y-%m-%d)"
fi

# --- Category from labels (default FEATURE) ---
if printf '%s' "$LABELS" | grep -q 'type:incident'; then
    CATEGORY="INCIDENT"
else
    CATEGORY="FEATURE"
fi

fi # end DRY_RUN / non-github-mode / github-mode

# --- Extract Background/Changes or Cause/Fix from body ---
# Recognizes inline (Field: value), H2 (## Field), and H3 (### Field) shapes,
# case-insensitive. Newlines are normalized to spaces for doc-append single-line args.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/extract-field.sh
source "$_SCRIPT_DIR/lib/extract-field.sh"

if [ "$CATEGORY" = "INCIDENT" ]; then
    CAUSE=$(extract_field_with_fallback Cause "$TITLE" "$BODY")
    FIX=$(extract_field_with_fallback Fix "$TITLE" "$BODY")
else
    BACKGROUND=$(extract_field_with_fallback Background "$TITLE" "$BODY")
    CHANGES=$(extract_field_with_fallback Changes "$TITLE" "$BODY")
fi

# --- History Notes synthesis (#412) ---
# When --history-notes-file is provided, extract bullet items from the
# `## History Notes` section (filtering `- (none)` placeholders). When the file
# has no such heading (e.g. mktemp inline path from /issue-close-finalize), the
# whole file is treated as notes. Joined with "; " and appended to Changes
# (or Fix for INCIDENT) as a "History Notes: ..." suffix.
if [ -n "$HISTORY_NOTES_FILE" ] && [ -f "$HISTORY_NOTES_FILE" ]; then
    if grep -qE '^## History Notes[[:space:]]*$' "$HISTORY_NOTES_FILE"; then
        NOTES_BLOCK=$(awk '
            /^## History Notes[[:space:]]*$/ { in_section=1; next }
            in_section && /^## / { in_section=0 }
            in_section && /^- / && !/^- \(none\)/ { sub(/^- /, ""); print }
        ' "$HISTORY_NOTES_FILE")
    else
        # Inline path: whole file, strip leading "- " if present, drop blank lines.
        NOTES_BLOCK=$(awk 'NF { sub(/^- /, ""); print }' "$HISTORY_NOTES_FILE")
    fi
    if [ -n "$NOTES_BLOCK" ]; then
        NOTES_FLAT=$(printf '%s' "$NOTES_BLOCK" | tr '\n' ';' | sed 's/;$//' | sed 's/;/; /g')
        if [ "$CATEGORY" = "INCIDENT" ]; then
            FIX="${FIX} (History Notes: ${NOTES_FLAT})"
        else
            CHANGES="${CHANGES} (History Notes: ${NOTES_FLAT})"
        fi
    fi
fi

if [ "$CATEGORY" = "INCIDENT" ]; then
    ARGS=(--category INCIDENT --date "$CLOSED_DATE" --subject "$TITLE" --cause "$CAUSE" --fix "$FIX")
else
    ARGS=(--category "$CATEGORY" --date "$CLOSED_DATE" --subject "$TITLE" --background "$BACKGROUND" --changes "$CHANGES")
fi

if [ -n "$COMMIT" ]; then
    ARGS+=(--commits "${COMMIT}, #${ISSUE_NUM}")
else
    ARGS+=(--commits "#${ISSUE_NUM}")
fi

# --- Append (or dry-run print) ---
if [ -n "${DRY_RUN:-}" ]; then
    echo "DRY_RUN: ${ARGS[*]}"
    exit 0
fi

if ! doc-append "${TARGET:-$HISTORY_FILE}" "${ARGS[@]}"; then
    echo "Error: doc-append failed" >&2
    exit 1
fi

echo "Appended issue #${ISSUE_NUM} to ${TARGET:-$HISTORY_FILE}"
