#!/usr/bin/env bash
# Batch migration: create GitHub Issues from <REPO_DIR>/docs/history.md and
# any archive files in <REPO_DIR>/docs/history/*.md (excluding index.md).
# Each entry is created with type:task (or type:incident) + status:migrated
# labels, then immediately closed (historical record — not an active task).
#
# Usage:
#   bin/github-issues/migration/migrate-history.sh <repo_dir> [--dry-run] [--canary N]
#     --dry-run : print titles/labels without calling gh
#     --canary N: stop when cumulative migrated count reaches N (not N additional)
#
# State integration: skips already-migrated entries via state_is_migrated.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/state.sh"

REPO_DIR="${1:?usage: migrate-history.sh <repo_dir> [--dry-run] [--canary N]}"
shift
DRY_RUN=0
CANARY_LIMIT=""
HISTORY_FILES_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --canary)        CANARY_LIMIT="${2:?--canary requires N}"; shift 2 ;;
    --history-files) HISTORY_FILES_ARG="${2:?--history-files requires comma-separated list}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

REPO_DIR="$(cd "$REPO_DIR" && pwd)"
HISTORY_FILE="$REPO_DIR/docs/history.md"
HISTORY_DIR="$REPO_DIR/docs/history"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] No GitHub API calls will be made"
fi

# State load (non-dry-run only).
if [ "$DRY_RUN" -eq 0 ]; then
  state_init "$REPO_DIR"
  state_load "$REPO_DIR"
fi

TMPDIR_ENTRIES=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ENTRIES"' EXIT

# split_entries <file> <output-dir> <start-n>
split_entries() {
  local file="$1" outdir="$2" start="$3"
  [ -f "$file" ] || return 0
  awk -v outdir="$outdir" -v start="$start" '
    function flush(n, heading, body,   label, title, f, idx) {
      if (n == 0) return
      label = "type:task"
      if (heading ~ /^INCIDENT:/) label = "type:incident"
      title = heading
      gsub(/^INCIDENT: #[0-9]+: /, "", title)
      gsub(/^[A-Z_]+: /, "", title)
      sub(/ \(20[0-9][0-9]-[0-9][0-9]-[0-9][0-9].*$/, "", title)
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

# Build the ordered list of history files to process.
ALL_HISTORY_FILES=()
if [ -n "$HISTORY_FILES_ARG" ]; then
  # Explicit list (comma-separated, relative to docs/history/).
  IFS=',' read -ra _raw_files <<< "$HISTORY_FILES_ARG"
  for _rel in "${_raw_files[@]}"; do
    _abs="$HISTORY_DIR/$_rel"
    if [ ! -f "$_abs" ]; then
      echo "ERROR: --history-files: file not found: $_abs" >&2
      exit 1
    fi
    ALL_HISTORY_FILES+=("$_abs")
  done
else
  # Auto-discovery: archives (alphabetical), then current history.md.
  if [ -d "$HISTORY_DIR" ]; then
    while IFS= read -r f; do
      case "$(basename "$f")" in
        index.md) ;;
        *) ALL_HISTORY_FILES+=("$f") ;;
      esac
    done < <(find "$HISTORY_DIR" -maxdepth 1 -name "*.md" 2>/dev/null | sort)
  fi
  [ -f "$HISTORY_FILE" ] && ALL_HISTORY_FILES+=("$HISTORY_FILE")
fi

# Assign stable entry IDs in declared/discovered order.
next_start=1
for _f in "${ALL_HISTORY_FILES[@]+${ALL_HISTORY_FILES[@]}}"; do
  [ -z "$_f" ] && continue
  split_entries "$_f" "$TMPDIR_ENTRIES" "$next_start"
  count=$(awk '/^### /{n++} END{print n+0}' "$_f" 2>/dev/null || echo 0)
  next_start=$(( next_start + count ))
done

total=$(find "$TMPDIR_ENTRIES" -name "*.title" 2>/dev/null | wc -l | tr -d ' ')
echo "Entries discovered: $total"

if [ "$total" -eq 0 ]; then
  echo "No entries to migrate."
  exit 0
fi

processed=0
created_this_run=0
for title_file in $(find "$TMPDIR_ENTRIES" -name "*.title" | sort); do
  base="${title_file%.title}"
  idx_name="$(basename "$base")"   # e.g. "0001"
  entry_id="h-${idx_name}"
  title=$(cat "$base.title")
  label=$(cat "$base.label")
  body_file="$base.body"

  if [ "$DRY_RUN" -eq 0 ]; then
    # Cumulative canary check: stop if state already has N entries.
    if [ -n "$CANARY_LIMIT" ]; then
      cur=$(state_count_migrated history)
      if [ "$cur" -ge "$CANARY_LIMIT" ]; then
        echo "[canary] cumulative migrated=$cur >= $CANARY_LIMIT — stopping"
        break
      fi
    fi
    if state_is_migrated history "$entry_id"; then
      echo "[skip] $entry_id already migrated"
      continue
    fi
  fi

  processed=$((processed + 1))
  printf "[%s] [%s] %s\n" "$entry_id" "$label" "$title"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  -> would: gh issue create + gh issue close"
    continue
  fi

  issue_url=$(cd "$REPO_DIR" && gh issue create \
    --title "$title" \
    --label "$label" \
    --label "status:migrated" \
    --body-file "$body_file")
  issue_num=$(echo "$issue_url" | sed 's|.*/issues/||' | grep -oE '^[0-9]+')
  if [ -z "$issue_num" ]; then
    echo "ERROR: could not parse issue number from: $issue_url" >&2
    exit 1
  fi
  echo "  -> created #$issue_num"

  (cd "$REPO_DIR" && ISSUE_CLOSE_SKILL=1 gh issue close "$issue_num" --reason completed) || true
  echo "  -> closed  #$issue_num"

  state_record_migrated history "$entry_id" "$issue_num" "$title"
  created_this_run=$((created_this_run + 1))
done

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
  echo "=== Dry run complete: $processed entries would be migrated ==="
else
  echo "=== Migration step complete: $created_this_run new issues created this run ==="
fi
