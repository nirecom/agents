#!/bin/bash
#
# bin/sweep-plans.sh
#
# Reclaim stale ~/.workflow-plans/ session artifacts. A "candidate" is a group
# of files sharing a session-id prefix (YYYYMMDD-HHMMSS or UUID) whose newest
# member is older than SWEEP_AGE_DAYS days.
#
# Usage:
#   sweep-plans.sh [--dry-run|--apply] [--ci-mode] [--sweep-age-days N]
#
# Deletes by default; pass --dry-run to preview.
#
# Exit codes:
#   0 — normal completion
#   2 — SWEEP_AGE_DAYS validation error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sweep-write-mode.sh
source "$SCRIPT_DIR/lib/sweep-write-mode.sh"

# ─── Defaults ──────────────────────────────────────────────────────────────

sweep_write_mode_init
CI_MODE=0
SWEEP_AGE_DAYS="${SWEEP_AGE_DAYS:-30}"

# ─── Validators ────────────────────────────────────────────────────────────

validate_sweep_age_days() {
  local v="$1"
  if [[ ! "$v" =~ ^[0-9]+$ ]] || [[ "$v" -lt 1 ]]; then
    printf 'ERROR: SWEEP_AGE_DAYS must be a positive integer (got: %s)\n' "$v" >&2
    exit 2
  fi
}

validate_sweep_age_days "$SWEEP_AGE_DAYS"

usage() {
  cat <<'EOF'
Usage: sweep-plans.sh [options]

Options:
EOF
  sweep_write_mode_usage_lines
  cat <<'EOF'
  --ci-mode             Emit JSON summary on stdout (instead of plain text).
  --sweep-age-days N    Age threshold in days (default 30; env SWEEP_AGE_DAYS).
  -h, --help            Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) sweep_write_mode_apply ;;
    --dry-run) sweep_write_mode_dry_run ;;
    --ci-mode) CI_MODE=1 ;;
    --sweep-age-days)
      shift
      SWEEP_AGE_DAYS="${1:?--sweep-age-days requires a value}"
      validate_sweep_age_days "$SWEEP_AGE_DAYS"
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'ERROR: unknown flag: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

# ─── PLANS_DIR resolution ──────────────────────────────────────────────────

if [[ -n "${AGENTS_CONFIG_DIR:-}" ]] && [[ -x "${AGENTS_CONFIG_DIR}/bin/workflow-plans-dir" ]]; then
  PLANS_DIR="$("${AGENTS_CONFIG_DIR}/bin/workflow-plans-dir" 2>/dev/null || echo "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}")"
else
  PLANS_DIR="${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
fi

if [[ ! -d "$PLANS_DIR" ]]; then
  if [[ "$CI_MODE" == "1" ]]; then
    printf '{"scanned":0,"groups_candidates":0,"groups_removed":0,"groups_skipped_young":0,"groups_skipped_revived":0,"files_removed":0,"files_skipped_unrecognized":0,"errors":[]}\n'
  else
    printf 'plans dir not found: %s\n' "$PLANS_DIR"
  fi
  exit 0
fi

# ─── Counters ──────────────────────────────────────────────────────────────

scanned=0
groups_candidates=0
groups_removed=0
groups_skipped_young=0
groups_skipped_revived=0
files_removed=0
files_skipped_unrecognized=0
errors=()

# ─── Helpers ───────────────────────────────────────────────────────────────

file_mtime() {
  local f="$1"
  stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0
}

format_date() {
  local epoch="$1"
  date -d "@${epoch}" +%Y-%m-%d 2>/dev/null \
    || date -r "${epoch}" +%Y-%m-%d 2>/dev/null \
    || printf '%s' "$epoch"
}

# ─── Group discovery ───────────────────────────────────────────────────────
#
# Walk depth-1 files under PLANS_DIR. For each file basename, extract the
# session-id prefix and group files by prefix. Four accepted shapes:
#   - YYYYMMDD-HHMMSS  (timestamp)
#   - UUID             (8-4-4-4-12 hex)
#   - <epoch>-<pid>    (10-digit unix epoch + numeric pid)
#   - empty            (basename starts with '-'; prefix=""))
# Files not matching any shape are skipped silently.

# Bash associative arrays reject empty string subscripts ("bad array subscript"),
# so the empty-prefix bucket (basenames like "-foo.md") is stored under the
# sentinel key EMPTY_PREFIX_KEY. The sentinel itself is never a valid prefix
# shape (contains '@'), so it cannot collide with any real session id.
declare -A PREFIX_FILES=()
EMPTY_PREFIX_KEY="__empty@@__"

# #847 guard — SSOT for which hyphen-prefixed basenames may enter the
# empty-SID bucket. Only workflow-generated artifacts match: a lowercase-kebab
# stem (allowing '.' and '_' as inner separators) plus one known machine
# extension. Anything else ("-scratch", "-My Notes.docx") is left on disk and
# counted in files_skipped_unrecognized.
#
# Fail-safe direction is deliberate: an unknown shape is never deleted. A new
# artifact kind that lands in the empty-SID bucket therefore accumulates rather
# than being lost, and the accumulation is observable via the counter.
EMPTY_PREFIX_ALLOW_RE='^-[a-z0-9]+([._-][a-z0-9]+)*\.(md|txt|json|jsonl|log|built|tmp|tsv|err|out|status|patch)$'

while IFS= read -r -d '' f; do
  scanned=$(( scanned + 1 ))
  basename="${f##*/}"
  if [[ "$basename" =~ ^([0-9]{8}-[0-9]{6}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9]{10}-[0-9]+)- ]]; then
    key="${BASH_REMATCH[1]}"
  elif [[ "$basename" == -* ]]; then
    if [[ ! "$basename" =~ $EMPTY_PREFIX_ALLOW_RE ]]; then
      files_skipped_unrecognized=$(( files_skipped_unrecognized + 1 ))
      continue
    fi
    key="$EMPTY_PREFIX_KEY"
  else
    continue
  fi
  PREFIX_FILES["$key"]+="$f"$'\n'
done < <(find "$PLANS_DIR" -maxdepth 1 -mindepth 1 -type f -print0 2>/dev/null)

# ─── Age computation + candidate selection ─────────────────────────────────

now_epoch="$(date +%s)"
threshold_epoch=$(( now_epoch - SWEEP_AGE_DAYS * 86400 ))

# Track candidate groups for the apply pass.
declare -a CAND_PREFIXES=()

for key in "${!PREFIX_FILES[@]}"; do
  files_blob="${PREFIX_FILES[$key]}"
  if [[ "$key" == "$EMPTY_PREFIX_KEY" ]]; then
    prefix=""
  else
    prefix="$key"
  fi
  min_mtime=0
  max_mtime=0
  file_count=0
  while IFS= read -r gf; do
    [[ -z "$gf" ]] && continue
    file_count=$(( file_count + 1 ))
    m="$(file_mtime "$gf")"
    if [[ ! "$m" =~ ^[0-9]+$ ]]; then m=0; fi
    if [[ "$file_count" -eq 1 ]]; then
      min_mtime="$m"
      max_mtime="$m"
    else
      [[ "$m" -lt "$min_mtime" ]] && min_mtime="$m"
      [[ "$m" -gt "$max_mtime" ]] && max_mtime="$m"
    fi
  done <<< "$files_blob"

  if [[ "$max_mtime" -ge "$threshold_epoch" ]]; then
    groups_skipped_young=$(( groups_skipped_young + 1 ))
    continue
  fi

  groups_candidates=$(( groups_candidates + 1 ))
  CAND_PREFIXES+=("$key")

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY-RUN: candidate session=%s files=%d oldest=%s newest=%s\n' \
      "$prefix" "$file_count" \
      "$(format_date "$min_mtime")" "$(format_date "$max_mtime")"
  fi
done

# ─── Apply pass ────────────────────────────────────────────────────────────

if [[ "$APPLY" == "1" ]] && [[ "${#CAND_PREFIXES[@]}" -gt 0 ]]; then
  for key in "${CAND_PREFIXES[@]}"; do
    files_blob="${PREFIX_FILES[$key]}"
    if [[ "$key" == "$EMPTY_PREFIX_KEY" ]]; then
      prefix=""
    else
      prefix="$key"
    fi
    # TOCTOU re-check: a session may have written or touched a matching file
    # after the scan. Recompute the group's newest mtime — including files
    # that appeared *after* the scan via the same prefix glob — and skip the
    # whole group if anything is now newer than the threshold.
    recheck_max=0
    while IFS= read -r gf; do
      [[ -z "$gf" ]] && continue
      [[ ! -e "$gf" ]] && continue
      rm="$(file_mtime "$gf")"
      [[ "$rm" =~ ^[0-9]+$ ]] || rm=0
      [[ "$rm" -gt "$recheck_max" ]] && recheck_max="$rm"
    done <<< "$files_blob"
    while IFS= read -r -d '' newgf; do
      # find returns a FULL PATH; EMPTY_PREFIX_ALLOW_RE is anchored at '^-', so
      # match on the basename. Scope the re-check to exactly what the delete
      # pass can touch: for the empty-SID bucket that is the allowlist, not
      # every '-' prefixed basename (#847, S1-2(b)).
      newgf_base="${newgf##*/}"
      if [[ "$key" == "$EMPTY_PREFIX_KEY" ]] && [[ ! "$newgf_base" =~ $EMPTY_PREFIX_ALLOW_RE ]]; then
        continue
      fi
      rm="$(file_mtime "$newgf")"
      [[ "$rm" =~ ^[0-9]+$ ]] || rm=0
      [[ "$rm" -gt "$recheck_max" ]] && recheck_max="$rm"
    done < <(find "$PLANS_DIR" -maxdepth 1 -mindepth 1 -type f -name "${prefix}-*" -print0 2>/dev/null)  # prefix="" → -name "-*": all '-' prefixed basenames, narrowed to EMPTY_PREFIX_ALLOW_RE above; portable on GNU and BSD find
    if [[ "$recheck_max" -ge "$threshold_epoch" ]]; then
      groups_skipped_revived=$(( groups_skipped_revived + 1 ))
      printf 'WARN: session %s touched since scan; skipping (revived)\n' "$prefix" >&2
      continue
    fi

    group_removed_any=0
    while IFS= read -r gf; do
      [[ -z "$gf" ]] && continue
      if rm -f -- "$gf" 2>/dev/null; then
        files_removed=$(( files_removed + 1 ))
        group_removed_any=1
      else
        errors+=("rm-failed:$gf")
      fi
    done <<< "$files_blob"
    if [[ "$group_removed_any" -eq 1 ]]; then
      groups_removed=$(( groups_removed + 1 ))
    fi
  done
fi

# ─── Summary output ────────────────────────────────────────────────────────

if [[ "$CI_MODE" == "1" ]]; then
  errs_json="[]"
  if [[ ${#errors[@]} -gt 0 ]]; then
    errs_json="$(printf '%s\n' "${errors[@]}" | node -e \
      'const xs=require("fs").readFileSync(0,"utf8").split(/\r?\n/).filter(Boolean);process.stdout.write(JSON.stringify(xs))')"
  fi
  printf '{"scanned":%d,"groups_candidates":%d,"groups_removed":%d,"groups_skipped_young":%d,"groups_skipped_revived":%d,"files_removed":%d,"files_skipped_unrecognized":%d,"errors":%s}\n' \
    "$scanned" "$groups_candidates" "$groups_removed" \
    "$groups_skipped_young" "$groups_skipped_revived" \
    "$files_removed" "$files_skipped_unrecognized" "$errs_json"
else
  printf 'sweep-plans summary:\n'
  printf '  scanned: %d\n' "$scanned"
  printf '  groups_candidates: %d\n' "$groups_candidates"
  printf '  groups_removed: %d\n' "$groups_removed"
  printf '  groups_skipped_young: %d\n' "$groups_skipped_young"
  printf '  groups_skipped_revived: %d\n' "$groups_skipped_revived"
  printf '  files_removed: %d\n' "$files_removed"
  printf '  files_skipped_unrecognized: %d\n' "$files_skipped_unrecognized"
  printf '  errors: %d\n' "${#errors[@]}"
  sweep_write_mode_footer
fi

exit 0
