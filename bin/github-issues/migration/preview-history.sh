#!/usr/bin/env bash
# Preview: list all history entries queued for GitHub Issues migration.
# Reads source files directly — no intermediate manifest.
# Run before migrate-history.sh to review titles, labels, and counts.
#
# Usage:
#   bin/github-issues/migration/preview-history.sh <repo_dir>
set -euo pipefail

REPO_DIR="${1:?usage: preview-history.sh <repo_dir> [--history-files <list>]}"
shift
HISTORY_FILES_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --history-files) HISTORY_FILES_ARG="${2:?--history-files requires comma-separated list}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
REPO_DIR="$(cd "$REPO_DIR" && pwd)"
HISTORY_FILE="$REPO_DIR/docs/history.md"
HISTORY_DIR="$REPO_DIR/docs/history"

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
echo "Repo: $REPO_DIR"
echo ""

n=0

# Build the ordered file list (explicit or auto-discovered).
ALL_PREVIEW_FILES=()
if [ -n "$HISTORY_FILES_ARG" ]; then
  IFS=',' read -ra _raw_files <<< "$HISTORY_FILES_ARG"
  for _rel in "${_raw_files[@]}"; do
    _abs="$HISTORY_DIR/$_rel"
    if [ ! -f "$_abs" ]; then
      echo "ERROR: --history-files: file not found: $_abs" >&2
      exit 1
    fi
    ALL_PREVIEW_FILES+=("$_abs")
  done
else
  if [ -d "$HISTORY_DIR" ]; then
    while IFS= read -r f; do
      case "$(basename "$f")" in
        index.md) ;;
        *) ALL_PREVIEW_FILES+=("$f") ;;
      esac
    done < <(find "$HISTORY_DIR" -maxdepth 1 -name "*.md" 2>/dev/null | sort)
  fi
  [ -f "$HISTORY_FILE" ] && ALL_PREVIEW_FILES+=("$HISTORY_FILE")
fi

# Print entries from each file in order.
for _f in "${ALL_PREVIEW_FILES[@]+${ALL_PREVIEW_FILES[@]}}"; do
  [ -z "$_f" ] && continue
  [ -f "$_f" ] || continue
  rel="${_f#"$REPO_DIR/"}"
  echo "--- $rel ---"
  file_count=0
  while IFS=$'\t' read -r label title; do
    n=$((n + 1))
    file_count=$((file_count + 1))
    printf "H-%03d [%s] %s\n" "$n" "$label" "$title"
  done < <(extract_headings "$_f")
  echo "    (subtotal: $file_count entries)"
  echo ""
done

echo "=== Count summary ==="
printf "Grand total         : %d entries\n" "$n"
