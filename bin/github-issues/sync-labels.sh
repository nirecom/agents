#!/bin/bash
# Apply .github/labels.yml to the current repository via `gh label create --force`.
#
# Usage: bin/github-issues/sync-labels.sh [path-to-labels.yml]
#
# Idempotent — `--force` overwrites existing labels with matching names so this
# can be re-run safely as the labels.yml evolves.

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

FAIL=0
COUNT=0
while IFS=$'\t' read -r NAME COLOR DESC; do
    [ -z "$NAME" ] && continue
    COUNT=$((COUNT + 1))
    echo "Applying label: $NAME (color=$COLOR)"
    if ! gh label create "$NAME" --color "$COLOR" --description "$DESC" --force; then
        echo "  Failed to apply $NAME" >&2
        FAIL=$((FAIL + 1))
    fi
done < <(parse_and_apply)

echo ""
echo "Applied $((COUNT - FAIL)) / $COUNT labels."
[ "$FAIL" -eq 0 ]
