#!/usr/bin/env bash
# Batch migration: create GitHub Issues from <REPO_DIR>/docs/todo.md.
# Each ## section becomes one open issue (type:task label, NOT closed).
# After full migration completes (no canary, not dry-run, all sections done),
# rewrite docs/todo.md as a thin ID index.
#
# Usage:
#   bin/github-issues/migration/migrate-todo.sh <repo_dir> [--dry-run] [--canary N]
#     --dry-run : print titles without calling gh
#     --canary N: stop when cumulative migrated count reaches N (not N additional)
#
# State integration: skips already-migrated entries via state_is_migrated.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/state.sh"

REPO_DIR="${1:?usage: migrate-todo.sh <repo_dir> [--dry-run] [--canary N]}"
shift
DRY_RUN=0
CANARY_LIMIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --canary)  CANARY_LIMIT="${2:?--canary requires N}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

REPO_DIR="$(cd "$REPO_DIR" && pwd)"
FILE_TODO="$REPO_DIR/docs/todo.md"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] No GitHub API calls will be made"
  echo ""
fi

# State load (non-dry-run only).
if [ "$DRY_RUN" -eq 0 ]; then
  state_init "$REPO_DIR"
  state_load "$REPO_DIR"
fi

TMPDIR_ENTRIES=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ENTRIES"' EXIT

# Parse `## Section` headers (not ###). Each section becomes one issue.
# Sections with no non-blank body lines (header-only or whitespace-only) are
# skipped: no .title/.body files are written for them. A .skip file is written
# instead so the summary can count them.
awk -v outdir="$TMPDIR_ENTRIES" '
  function has_content(body,   i, line) {
    # Return 1 if body has at least one non-blank line that is not the ## header
    for (i = 2; i <= split(body, a, "\n"); i++) {
      line = a[i]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line != "") return 1
    }
    return 0
  }
  function flush(n, heading, body,   f) {
    if (n == 0) return
    while (substr(body, length(body) - 1) == "\n\n")
      body = substr(body, 1, length(body) - 1)
    if (!has_content(body)) {
      f = sprintf("%s/%04d.skip", outdir, n); print heading > f; close(f)
      print "SKIP: empty section \"" heading "\""
      return
    }
    f = sprintf("%s/%04d.title", outdir, n); print heading > f; close(f)
    f = sprintf("%s/%04d.body",  outdir, n); printf "%s", body > f; close(f)
  }
  /^## / {
    flush(n, heading, body)
    n++; heading = substr($0, 4); body = $0 "\n"; next
  }
  n > 0 { body = body $0 "\n" }
  END    { flush(n, heading, body) }
' "$FILE_TODO"

total=$(find "$TMPDIR_ENTRIES" -name "*.title" 2>/dev/null | wc -l | tr -d ' ')
skipped_this_run=$(find "$TMPDIR_ENTRIES" -name "*.skip" 2>/dev/null | wc -l | tr -d ' ')
echo "Sections discovered: $total (skipped empty: $skipped_this_run)"

if [ "$total" -eq 0 ]; then
  echo "No sections to migrate."
  exit 0
fi

processed=0
created_this_run=0
for title_file in $(find "$TMPDIR_ENTRIES" -name "*.title" | sort); do
  base="${title_file%.title}"
  idx_name="$(basename "$base")"
  entry_id="t-${idx_name}"
  title=$(cat "$base.title")
  body_file="$base.body"

  if [ "$DRY_RUN" -eq 0 ]; then
    if [ -n "$CANARY_LIMIT" ]; then
      cur=$(state_count_migrated todo)
      if [ "$cur" -ge "$CANARY_LIMIT" ]; then
        echo "[canary] cumulative migrated=$cur >= $CANARY_LIMIT — stopping"
        break
      fi
    fi
    if state_is_migrated todo "$entry_id"; then
      echo "[skip] $entry_id already migrated"
      continue
    fi
  fi

  processed=$((processed + 1))
  printf "[%s] %s\n" "$entry_id" "$title"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  -> would: gh issue create (open, type:task)"
    continue
  fi

  issue_url=$(cd "$REPO_DIR" && gh issue create \
    --title "$title" \
    --label "type:task" \
    --body-file "$body_file")
  issue_num="${issue_url##*/}"
  if [ -z "$issue_num" ]; then
    echo "ERROR: could not parse issue number from: $issue_url" >&2
    exit 1
  fi
  echo "  -> created #$issue_num"

  state_record_migrated todo "$entry_id" "$issue_num" "$title"
  created_this_run=$((created_this_run + 1))
done

# Bug fix: only rewrite todo.md after FULL migration (no canary, not dry-run,
# all sections migrated).
if [ -z "$CANARY_LIMIT" ] && [ "$DRY_RUN" -eq 0 ] && \
   [ "$(state_count_migrated todo)" -eq "$total" ]; then
  cp "$REPO_DIR/docs/todo.md" "$REPO_DIR/docs/todo.md.bak"
  {
    printf "# Active Tasks\n\nSee GitHub Issues for current work.\n\n"
    jq -r '.todo.migrated[] | "- #\(.issue_number) — \(.title)"' "$STATE_FILE"
  } > "$REPO_DIR/docs/todo.md"
  tmp="${STATE_FILE}.tmp"
  jq '.todo.todo_md_rewritten = true' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
  echo "  -> todo.md rewritten as ID index (backup: docs/todo.md.bak)"
fi

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
  echo "=== Dry run complete: $processed sections would be migrated, $skipped_this_run skipped (empty) ==="
else
  echo "=== Migration step complete: $created_this_run new issues created, $skipped_this_run skipped (empty) this run ==="
fi
