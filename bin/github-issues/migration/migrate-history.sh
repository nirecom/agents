#!/usr/bin/env bash
# Batch migration: create GitHub Issues from docs/history/2026.md + docs/history.md.
# Each entry is created with type:task (or type:incident) + status:migrated labels,
# then immediately closed (historical record — not an active task).
#
# Usage:
#   bin/github-issues/migration/migrate-history.sh [--dry-run]
#   --dry-run: print titles/labels without calling gh
#
# Prerequisites: labels must exist (run bin/github-issues/sync-labels.sh if needed).
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FILE_2026="$AGENTS_DIR/docs/history/2026.md"
FILE_CURRENT="$AGENTS_DIR/docs/history.md"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  echo "[dry-run] No GitHub API calls will be made"
  echo ""
fi

TMPDIR_ENTRIES=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ENTRIES"' EXIT

# split_entries <file> <output-dir> <start-n>
# Writes per-entry files: <NNNN>.title  <NNNN>.label  <NNNN>.body
split_entries() {
  local file="$1" outdir="$2" start="$3"
  awk -v outdir="$outdir" -v start="$start" '
    function flush(n, heading, body,   label, title, f) {
      if (n == 0) return
      label = "type:task"
      if (heading ~ /^INCIDENT:/) label = "type:incident"
      title = heading
      gsub(/^INCIDENT: #[0-9]+: /, "", title)
      gsub(/^[A-Z_]+: /, "", title)
      sub(/ \(20[0-9][0-9]-[0-9][0-9]-[0-9][0-9].*$/, "", title)
      # strip trailing blank lines from body
      while (substr(body, length(body) - 1) == "\n\n")
        body = substr(body, 1, length(body) - 1)

      idx = start + n - 1
      f = sprintf("%s/%04d.title", outdir, idx); print title  > f; close(f)
      f = sprintf("%s/%04d.label", outdir, idx); print label  > f; close(f)
      f = sprintf("%s/%04d.body",  outdir, idx); printf "%s", body > f; close(f)
    }
    /^### / {
      flush(n, heading, body)
      n++; heading = substr($0, 5); body = $0 "\n"; next
    }
    n > 0 { body = body $0 "\n" }
    END    { flush(n, heading, body) }
  ' "$file"
}

split_entries "$FILE_2026"    "$TMPDIR_ENTRIES" 1
split_entries "$FILE_CURRENT" "$TMPDIR_ENTRIES" 83   # 82 entries in 2026.md

total=$(find "$TMPDIR_ENTRIES" -name "*.title" | wc -l | tr -d ' ')
echo "Entries to migrate: $total (expected 157)"
if [ "$total" -ne 157 ]; then
  echo "ERROR: unexpected entry count — run bin/preview-history-issues.sh to diagnose"
  exit 1
fi
echo ""

n=0
for title_file in $(find "$TMPDIR_ENTRIES" -name "*.title" | sort); do
  n=$((n + 1))
  base="${title_file%.title}"
  title=$(cat "$base.title")
  label=$(cat "$base.label")
  body_file="$base.body"

  printf "[%d/%d] [%s] %s\n" "$n" "$total" "$label" "$title"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  -> would: gh issue create + gh issue close"
    continue
  fi

  issue_url=$(cd "$AGENTS_DIR" && gh issue create \
    --title "$title" \
    --label "$label" \
    --label "status:migrated" \
    --body-file "$body_file")
  issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$')
  echo "  -> created #$issue_num"

  (cd "$AGENTS_DIR" && ISSUE_CLOSE_SKILL=1 gh issue close "$issue_num" --reason completed)
  echo "  -> closed  #$issue_num"
done

echo ""
echo "=== Migration complete: $n issues created and closed ==="
