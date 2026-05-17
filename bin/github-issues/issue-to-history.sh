#!/bin/bash
# Convert a (typically closed) GitHub issue into a docs/history.md entry.
#
# Usage: bin/github-issues/issue-to-history.sh <issue-number> [--commit <hash>]
#
# Requires AGENTS_CONFIG_DIR (the docs/ root). The script cd's there before
# writing so consumer repos can pass their own value to target the right
# history.md.
#
# Idempotent: if `#<N>:` already appears in docs/history.md or docs/history/,
# exits 0 without re-appending.

set -uo pipefail

# --- Argument parsing ---
if [ $# -lt 1 ]; then
    echo "Usage: $0 <issue-number> [--commit <hash>]" >&2
    exit 1
fi

ISSUE_NUM="$1"
shift

# Pure digits only — guards against shell injection via positional arg.
if ! printf '%s' "$ISSUE_NUM" | grep -qE '^[0-9]+$'; then
    echo "Error: issue number must be digits only, got: $ISSUE_NUM" >&2
    exit 1
fi

COMMIT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --commit)
            COMMIT="${2:-}"
            # Validate commit hash: 7-40 hex chars only.
            if [ -n "$COMMIT" ] && ! printf '%s' "$COMMIT" | grep -qE '^[0-9a-fA-F]{7,40}$'; then
                echo "Error: --commit must be a 7-40 char hex hash, got: $COMMIT" >&2
                exit 1
            fi
            shift 2
            ;;
        *) shift ;;
    esac
done

# --- Environment check ---
if [ -z "${AGENTS_CONFIG_DIR:-}" ]; then
    echo "Error: AGENTS_CONFIG_DIR is not set. /issue-close-stage and /issue-close-finalize must be run from a session that has it configured." >&2
    exit 1
fi

cd "$AGENTS_CONFIG_DIR" || { echo "Error: failed to cd into AGENTS_CONFIG_DIR=$AGENTS_CONFIG_DIR" >&2; exit 1; }

HISTORY_FILE="docs/history.md"
HISTORY_DIR="docs/history"

# --- Idempotency: skip if `### #N:` heading already present in history.md or rotated archive ---
# Anchor on `### ` prefix to avoid false-positive matches against in-body references
# like "follow-up from #42:" or "see also #42: ...".
if grep -rqE "(^### #${ISSUE_NUM}:)|(^### [^(]+ \([^)]+, #${ISSUE_NUM}\))" "$HISTORY_FILE" "$HISTORY_DIR" 2>/dev/null; then
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

# --- Extract Background/Changes or Cause/Fix from body ---
# Captures everything from `Field:` until the next known field header (or EOF),
# so multi-line textarea content from GitHub issue forms is preserved. Newlines
# inside the captured value are normalized to spaces because doc-append expects
# single-line arguments.
extract_field() {
    # $1 = field name (Background, Changes, Cause, Fix)
    printf '%s\n' "$BODY" | awk -v F="$1" '
        BEGIN { cap = 0; out = "" }
        $0 ~ "^(Background|Changes|Cause|Fix):" {
            if (cap) { cap = 0 }
            if ($0 ~ "^"F":") {
                line = $0
                sub("^"F":[ \t]*", "", line)
                out = line
                cap = 1
                next
            }
        }
        cap && /./ {
            out = (out == "" ? $0 : out " " $0)
        }
        END { print out }
    '
}

if [ "$CATEGORY" = "INCIDENT" ]; then
    CAUSE=$(extract_field Cause)
    FIX=$(extract_field Fix)
    ARGS=(--category INCIDENT --date "$CLOSED_DATE" --subject "$TITLE" --cause "$CAUSE" --fix "$FIX")
else
    BACKGROUND=$(extract_field Background)
    CHANGES=$(extract_field Changes)
    ARGS=(--category "$CATEGORY" --date "$CLOSED_DATE" --subject "$TITLE" --background "$BACKGROUND" --changes "$CHANGES")
fi

if [ -n "$COMMIT" ]; then
    ARGS+=(--commits "${COMMIT}, #${ISSUE_NUM}")
else
    ARGS+=(--commits "#${ISSUE_NUM}")
fi

# --- Append ---
if ! doc-append "$HISTORY_FILE" "${ARGS[@]}"; then
    echo "Error: doc-append failed" >&2
    exit 1
fi

echo "Appended issue #${ISSUE_NUM} to ${HISTORY_FILE}"
