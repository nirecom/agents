#!/usr/bin/env bash
# Preview: list all history entries queued for GitHub Issues migration.
# Reads source files directly — no intermediate manifest.
# Run before migrate-history-to-issues.sh to review titles, labels, and counts.
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FILE_2026="$AGENTS_DIR/docs/history/2026.md"
FILE_CURRENT="$AGENTS_DIR/docs/history.md"

# extract_headings <file>
# Prints one line per ### entry: "<type:task|type:incident>\t<clean title>"
extract_headings() {
  awk '
    /^### / {
      line = substr($0, 5)
      label = "type:task"
      if (line ~ /^INCIDENT:/) label = "type:incident"
      gsub(/^INCIDENT: #[0-9]+: /, "", line)
      gsub(/^[A-Z_]+: /, "", line)
      sub(/ \(20[0-9][0-9]-[0-9][0-9]-[0-9][0-9].*$/, "", line)
      printf "%s\t%s\n", label, line
    }
  ' "$1"
}

echo "=== History migration preview ==="
echo ""

n=0

echo "--- docs/history/2026.md ---"
count_2026=0
while IFS=$'\t' read -r label title; do
  n=$((n + 1))
  count_2026=$((count_2026 + 1))
  printf "H-%03d [%s] %s\n" "$n" "$label" "$title"
done < <(extract_headings "$FILE_2026")

echo ""
echo "--- docs/history.md (current) ---"
count_current=0
while IFS=$'\t' read -r label title; do
  n=$((n + 1))
  count_current=$((count_current + 1))
  printf "H-%03d [%s] %s\n" "$n" "$label" "$title"
done < <(extract_headings "$FILE_CURRENT")

echo ""
echo "=== Count verification ==="
printf "docs/history/2026.md : %d entries\n" "$count_2026"
printf "docs/history.md      : %d entries\n" "$count_current"
printf "Total                : %d entries\n" "$n"
echo ""
echo "Expected: 2026=82, current=75, total=157"
if [ "$count_2026" -eq 82 ] && [ "$count_current" -eq 75 ] && [ "$n" -eq 157 ]; then
  echo "PASS: counts match"
else
  echo "FAIL: count mismatch -- review before running migration"
  exit 1
fi
