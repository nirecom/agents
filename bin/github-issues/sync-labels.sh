#!/bin/bash
# Apply .github/labels.yml to the current repository via `gh label create`.
#
# Usage: bin/github-issues/sync-labels.sh [path-to-labels.yml]
#
# Three-way diff: labels not on remote are created (no --force), labels that
# differ are updated (--force), labels that already match are skipped entirely.

set -uo pipefail

LABELS_FILE="${1:-.github/labels.yml}"

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

if ! EXISTING=$(gh label list --json name,color,description --limit 1000 \
                  --jq '.[] | [.name, .color, .description] | @tsv'); then
    echo "error: gh label list failed; cannot determine existing labels" >&2
    exit 1
fi

CREATED=0
UPDATED=0
SKIPPED=0
FAIL=0

while IFS=$'\t' read -r ACTION NAME COLOR DESC; do
    [ -z "$ACTION" ] && continue
    case "$ACTION" in
        CREATE)
            printf '%b%s (created)%b\n' "$C_GREEN" "$NAME" "$C_RESET"
            if ! gh label create "$NAME" --color "$COLOR" --description "$DESC"; then
                echo "  Failed to create $NAME" >&2
                FAIL=$((FAIL + 1))
            else
                CREATED=$((CREATED + 1))
            fi
            ;;
        UPDATE)
            printf '%b%s (updated)%b\n' "$C_YELLOW" "$NAME" "$C_RESET"
            if ! gh label create "$NAME" --color "$COLOR" --description "$DESC" --force; then
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
    esac
done < <(awk '
    BEGIN { FS = OFS = "\t" }
    NR == FNR { existing[$1] = $2 OFS $3; next }
    {
      key = $1
      if (!(key in existing))              { print "CREATE", $1, $2, $3 }
      else if (existing[key] == $2 OFS $3) { print "SKIP",   $1, $2, $3 }
      else                                  { print "UPDATE", $1, $2, $3 }
    }
' <(printf '%s\n' "$EXISTING") <(parse_and_apply))

TOTAL=$((CREATED + UPDATED + SKIPPED + FAIL))
echo "$CREATED created, $UPDATED updated, $SKIPPED already-exists / $TOTAL total"
[ "$FAIL" -eq 0 ]
