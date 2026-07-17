#!/bin/bash
# Apply .github/labels.yml to the current repository via `gh label create`.
#
# Usage: bin/github-issues/sync-labels.sh [--repo OWNER/REPO] [path-to-labels.yml]
#
# Three-way diff: labels not on remote are created (no --force), labels that
# differ are updated (--force), labels that already match are skipped entirely.
#
# --repo OWNER/REPO targets a repo other than the CWD repo (cross-repo sync).
# Threaded into every gh label list/create call. Without it, gh resolves the
# repo from the current working directory (backward compatible).

set -uo pipefail

REPO_FLAG=""
REPO_FLAG_SET=0
LABELS_FILE=""
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --repo)
            if [ $# -lt 2 ]; then
                echo "Error: --repo requires a value" >&2; exit 2
            fi
            REPO_FLAG="$2"
            REPO_FLAG_SET=1
            shift 2
            ;;
        --repo=*)
            REPO_FLAG="${1#--repo=}"
            REPO_FLAG_SET=1
            shift
            ;;
        *)
            if [ -z "$LABELS_FILE" ]; then LABELS_FILE="$1"
            else echo "Error: extra positional argument: $1" >&2; exit 2
            fi
            shift
            ;;
    esac
done

# When --repo is supplied, its value must be a strict OWNER/REPO. `[[ =~ ]]`
# anchors on the whole string (unlike line-oriented grep), rejecting embedded
# newlines and other injection payloads. An empty value is invalid too.
if [ "$REPO_FLAG_SET" -eq 1 ]; then
    if ! [[ "$REPO_FLAG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        echo "Error: invalid --repo value: $REPO_FLAG" >&2; exit 2
    fi
fi

[ -z "$LABELS_FILE" ] && LABELS_FILE=".github/labels.yml"

if [ ! -f "$LABELS_FILE" ]; then
    echo "Error: labels file not found: $LABELS_FILE" >&2
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI not found" >&2
    exit 1
fi

C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_GRAY='\033[0;90m'
C_RED='\033[0;31m'
C_RESET='\033[0m'

# Parse the YAML with a small awk script. We only support the limited schema
# used by .github/labels.yml: a flat list of {name, color, description}.
# Lines look like:
#   - name: "type:task"
#     color: "0e8a16"
#     description: "..."
parse_and_apply() {
    awk '
        function strip(s) { gsub(/^[ \t]*[-]?[ \t]*[a-zA-Z_]+:[ \t]*/, "", s); gsub(/^"/, "", s); gsub(/"$/, "", s); return s }
        /^[ \t]*#/ { next }
        /^[ \t]*-[ \t]*name:/ {
            if (name != "") print name "\t" color "\t" desc
            name = strip($0); color = ""; desc = ""; next
        }
        /^[ \t]+color:/ { color = strip($0); next }
        /^[ \t]+description:/ { desc = strip($0); next }
        END { if (name != "") print name "\t" color "\t" desc }
    ' "$LABELS_FILE"
}

if ! EXISTING=$(gh label list ${REPO_FLAG:+--repo "$REPO_FLAG"} --json name,color,description --limit 1000 \
                  --jq '.[] | [.name, .color, .description] | @tsv'); then
    echo "error: gh label list failed; cannot determine existing labels" >&2
    exit 1
fi

CREATED=0
UPDATED=0
SKIPPED=0
FAIL=0
DELETED=0

while IFS=$'\t' read -r ACTION NAME COLOR DESC; do
    [ -z "$ACTION" ] && continue
    case "$ACTION" in
        CREATE)
            printf '%b%s (created)%b\n' "$C_GREEN" "$NAME" "$C_RESET"
            if [[ "$DRY_RUN" -eq 1 ]]; then
                printf '  [DRY-RUN] Would create: %s\n' "$NAME"
                CREATED=$((CREATED + 1))
            elif ! gh label create ${REPO_FLAG:+--repo "$REPO_FLAG"} "$NAME" --color "$COLOR" --description "$DESC"; then
                echo "  Failed to create $NAME" >&2
                FAIL=$((FAIL + 1))
            else
                CREATED=$((CREATED + 1))
            fi
            ;;
        UPDATE)
            printf '%b%s (updated)%b\n' "$C_YELLOW" "$NAME" "$C_RESET"
            if [[ "$DRY_RUN" -eq 1 ]]; then
                printf '  [DRY-RUN] Would update: %s\n' "$NAME"
                UPDATED=$((UPDATED + 1))
            elif ! gh label create ${REPO_FLAG:+--repo "$REPO_FLAG"} "$NAME" --color "$COLOR" --description "$DESC" --force; then
                echo "  Failed to update $NAME" >&2
                FAIL=$((FAIL + 1))
            else
                UPDATED=$((UPDATED + 1))
            fi
            ;;
        SKIP)
            printf '%b%s (already exists)%b\n' "$C_GRAY" "$NAME" "$C_RESET"
            SKIPPED=$((SKIPPED + 1))
            ;;
        DELETE)
            printf '%b%s (deleted)%b\n' "$C_RED" "$NAME" "$C_RESET"
            if [[ "$DRY_RUN" -eq 1 ]]; then
                printf '  [DRY-RUN] Would delete: %s\n' "$NAME"
                DELETED=$((DELETED + 1))
            elif ! gh label delete ${REPO_FLAG:+--repo "$REPO_FLAG"} "$NAME" --yes; then
                echo "  Failed to delete $NAME" >&2
                FAIL=$((FAIL + 1))
            else
                DELETED=$((DELETED + 1))
            fi
            ;;
    esac
done < <(awk '
    BEGIN { FS = OFS = "\t" }
    NR == FNR { if ($1 != "") existing[$1] = $2 OFS $3; next }
    {
      key = $1
      if (key == "") next
      yml_seen[key] = 1
      if (!(key in existing))              { print "CREATE", $1, $2, $3 }
      else if (existing[key] == $2 OFS $3) { print "SKIP",   $1, $2, $3 }
      else                                  { print "UPDATE", $1, $2, $3 }
    }
    END {
      for (k in existing) {
        if (!(k in yml_seen)) { print "DELETE", k }
      }
    }
' <(printf '%s\n' "$EXISTING") <(parse_and_apply))

TOTAL=$((CREATED + UPDATED + SKIPPED + DELETED + FAIL))
echo "$CREATED created, $UPDATED updated, $SKIPPED already-exists, $DELETED deleted / $TOTAL total"
[ "$FAIL" -eq 0 ]
