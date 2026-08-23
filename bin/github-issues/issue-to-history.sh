#!/bin/bash
# STANDALONE TOOL — no skill or workflow routes here; run it by hand for
# /issue-reconcile backfill or out-of-band history repair. Close-path
# docs/history.md writes belong to /worktree-end Step WE-21 (#690).

# Convert a (typically closed) GitHub issue into a docs/history.md entry.
# Usage: issue-to-history.sh <issue-number> [--commit <hash>]
#   [--history-notes-file <path>] [--target <abs-path>] [--allow-backdate]
#   [--no-auto-rotate] [--non-github-mode --title <t> --body-file <f>
#   --closed-date <YYYY-MM-DD>]
# Each flag, AGENTS_CONFIG_DIR and the idempotency guard are documented at
# their use site below.

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
ALLOW_BACKDATE=0
NO_AUTO_ROTATE=0

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
        --allow-backdate)
            ALLOW_BACKDATE=1
            shift
            ;;
        --no-auto-rotate)
            NO_AUTO_ROTATE=1
            shift
            ;;
        *) shift ;;
    esac
done

# --- Environment check ---
# AGENTS_CONFIG_DIR is the docs/ root; the script cd's there before writing so
# a consumer repo can target its own history.md.
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
# --target redirects the append away from the canonical pair, so the target and
# its sibling archive must be checked too — the canonical pair alone cannot see
# an entry already appended to the target, and a re-run would duplicate it.
CHECK_PATHS=("$HISTORY_FILE" "$HISTORY_DIR")
if [ -n "$TARGET" ]; then
    CHECK_PATHS+=("$TARGET" "$(dirname "$TARGET")/$(basename "$TARGET" .md)")
fi
if LC_ALL=C.UTF-8 "$GREP_BIN" -rPq "(^### #${ISSUE_NUM}\b)|(^### [^(]+ \([^)]+#${ISSUE_NUM}\b[^)]*\))|(^### [^\n]*#${ISSUE_NUM}\b[^\n]*\([0-9]{4}-)" "${CHECK_PATHS[@]}" 2>/dev/null; then
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
# An unextractable field becomes a `(no <Field> recorded)` marker; the title and the
# body's first line are never reused as a stand-in (#2098).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/extract-field.sh
source "$_SCRIPT_DIR/lib/extract-field.sh"

# require_field <VARNAME> <Field>: assign the extracted value, or abort.
# A plain `VAR=$(...)` discards the substitution status, so without this a
# parse failure (rc=3) would reach doc-append and mutate history. A
# `(no <Field> recorded)` marker is a success and still flows through.
require_field() {
    local __value
    if ! __value=$(extract_field_or_marker "$2"); then
        echo "Error: issue #${ISSUE_NUM}: could not extract ${2} from the issue body; aborting before doc-append (history unchanged)" >&2
        exit 1
    fi
    printf -v "$1" '%s' "$__value"
}

if [ "$CATEGORY" = "INCIDENT" ]; then
    require_field CAUSE Cause
    require_field FIX Fix
else
    require_field BACKGROUND Background
    require_field CHANGES Changes
fi

# --- History Notes synthesis (#412) ---
# When --history-notes-file is provided, extract bullet items from the
# `## History Notes` section (filtering `- (none)` placeholders). CI-only
# ISSUE_CLOSE_HISTORY_NOTES_NONINTERACTIVE=1 makes /issue-close-finalize Step E.1
# skip the inline-notes prompt; not user-facing, never in .env.example.
# When the file
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

# Forwarded verbatim: lifts doc-append's ascending-date guard so an issue
# closed long ago can still be recorded (required for /issue-reconcile backfill).
if [ "$ALLOW_BACKDATE" -eq 1 ]; then
    ARGS+=(--allow-backdate)
fi

if [ "$NO_AUTO_ROTATE" -eq 1 ]; then
    ARGS+=(--no-auto-rotate)
fi

# --- Append (or dry-run print) ---
if [ -n "${DRY_RUN:-}" ]; then
    echo "DRY_RUN: ${ARGS[*]}"
    exit 0
fi

# --target redirects the append to a staging file (step-e.sh, fetched via the
# GitHub Contents API) instead of docs/history.md.
if ! doc-append "${TARGET:-$HISTORY_FILE}" "${ARGS[@]}"; then
    echo "Error: doc-append failed" >&2
    exit 1
fi

echo "Appended issue #${ISSUE_NUM} to ${TARGET:-$HISTORY_FILE}"
