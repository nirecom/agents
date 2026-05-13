#!/usr/bin/env bash
# Batch migration: create GitHub Issues from docs/todo.md.
# Each ### section becomes one open issue (type:task label, NOT closed).
# After running, rewrite docs/todo.md as a thin ID index.
#
# Usage:
#   bin/migrate-todo-to-issues.sh [--dry-run]
#   --dry-run: print titles without calling gh
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FILE_TODO="$AGENTS_DIR/docs/todo.md"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  echo "[dry-run] No GitHub API calls will be made"
  echo ""
fi

TMPDIR_ENTRIES=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ENTRIES"' EXIT

awk -v outdir="$TMPDIR_ENTRIES" '
  function flush(n, heading, body,   f) {
    if (n == 0) return
    while (substr(body, length(body) - 1) == "\n\n")
      body = substr(body, 1, length(body) - 1)
    f = sprintf("%s/%04d.title", outdir, n); print heading > f; close(f)
    f = sprintf("%s/%04d.body",  outdir, n); printf "%s", body > f; close(f)
  }
  /^### / {
    flush(n, heading, body)
    n++; heading = substr($0, 5); body = $0 "\n"; next
  }
  n > 0 { body = body $0 "\n" }
  END    { flush(n, heading, body) }
' "$FILE_TODO"

total=$(find "$TMPDIR_ENTRIES" -name "*.title" | wc -l | tr -d ' ')
echo "Issues to create: $total (expected 24)"
if [ "$total" -ne 24 ]; then
  echo "ERROR: unexpected section count -- check docs/todo.md"
  exit 1
fi
echo ""

n=0
for title_file in $(find "$TMPDIR_ENTRIES" -name "*.title" | sort); do
  n=$((n + 1))
  base="${title_file%.title}"
  title=$(cat "$base.title")
  body_file="$base.body"

  printf "[%d/%d] %s\n" "$n" "$total" "$title"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  -> would: gh issue create (open, type:task)"
    continue
  fi

  issue_url=$(cd "$AGENTS_DIR" && gh issue create \
    --title "$title" \
    --label "type:task" \
    --body-file "$body_file")
  issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$')
  echo "  -> created #$issue_num"
done

echo ""
echo "=== Migration complete: $n issues created (open) ==="
