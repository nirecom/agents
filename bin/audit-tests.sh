#!/usr/bin/env bash
# audit-tests.sh — Staleness checker for issue-specific test files.
#
# Usage: bin/audit-tests.sh [--stale-months N] [--offline] [--format text|json]
# Exit:  0 = candidates found, 1 = no candidates, 2 = error
#
# Scans top-level tests/feature-NNN-*.sh files. For each, locates the optional
# sibling tests/<stem>/ folder, computes MAX last-commit date across both,
# and (when online) checks the matching GitHub issue's state. Files whose
# issue is CLOSED and whose last-commit is older than N months (default 3)
# are reported as deletion candidates.

set -euo pipefail

STALE_MONTHS=3
OFFLINE=0
FORMAT=text

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stale-months)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --stale-months requires an argument" >&2
        exit 2
      fi
      STALE_MONTHS="$2"
      shift 2
      ;;
    --offline)
      OFFLINE=1
      shift
      ;;
    --format)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --format requires an argument" >&2
        exit 2
      fi
      FORMAT="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$FORMAT" != "text" && "$FORMAT" != "json" ]]; then
  echo "ERROR: --format must be text or json" >&2
  exit 2
fi

if ! [[ "$STALE_MONTHS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --stale-months must be a non-negative integer" >&2
  exit 2
fi

# Resolve repo root via git.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  echo "ERROR: not inside a git repository" >&2
  exit 2
fi
cd "$REPO_ROOT"

if [[ ! -d tests ]]; then
  echo "ERROR: tests/ directory not found at repo root" >&2
  exit 2
fi

# Compute cutoff date (ISO YYYY-MM-DD). Prefer GNU date -d; fall back to python.
CUTOFF_DAYS=$(( STALE_MONTHS * 30 ))
CUTOFF_DATE=""
if date -d "${CUTOFF_DAYS} days ago" +%Y-%m-%d >/dev/null 2>&1; then
  CUTOFF_DATE="$(date -d "${CUTOFF_DAYS} days ago" +%Y-%m-%d)"
else
  CUTOFF_DATE="$(uv run python -c "import datetime; print((datetime.date.today() - datetime.timedelta(days=${CUTOFF_DAYS})).isoformat())")"
fi

TODAY="$(date +%Y-%m-%d)"

# Determine repo OWNER/NAME for gh api.
REPO_SLUG=""
GH_OK=0
if [[ "$OFFLINE" -eq 0 ]]; then
  if command -v gh >/dev/null 2>&1; then
    if REPO_SLUG="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null)"; then
      GH_OK=1
    else
      echo "WARNING: gh repo view failed — falling back to offline mode" >&2
      OFFLINE=1
    fi
  else
    echo "WARNING: gh CLI not found — falling back to offline mode" >&2
    OFFLINE=1
  fi
fi

# Header.
if [[ "$FORMAT" == "text" ]]; then
  echo "# audit-tests.sh report — ${TODAY}"
  echo "# Criteria: feature-NNN-* pattern, issue CLOSED, last-commit > ${STALE_MONTHS} months ago (cutoff ${CUTOFF_DATE})"
  if [[ "$OFFLINE" -eq 1 ]]; then
    echo "# Mode: OFFLINE (issue-state checks skipped — no candidates will be emitted)"
  fi
  echo ""
fi

CANDIDATES=()
JSON_ITEMS=()

shopt -s nullglob
for dispatcher in tests/feature-[0-9]*-*.sh; do
  base="$(basename "$dispatcher")"
  # Extract issue number: first numeric run after "feature-".
  if [[ ! "$base" =~ ^feature-([0-9]+)- ]]; then
    continue
  fi
  issue_num="${BASH_REMATCH[1]}"
  stem="${base%.sh}"
  sibling="tests/${stem}"

  # Validate # Tests: header (warn if listed path missing).
  tests_header="$(grep -m1 -E '^# Tests:' "$dispatcher" 2>/dev/null || true)"
  if [[ -n "$tests_header" ]]; then
    paths_csv="${tests_header#\# Tests:}"
    paths_csv="${paths_csv# }"
    IFS=',' read -r -a paths_arr <<< "$paths_csv"
    for p in "${paths_arr[@]}"; do
      p_trim="$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -z "$p_trim" ]] && continue
      if [[ ! -e "$p_trim" ]]; then
        echo "WARNING: ${dispatcher}: # Tests: path missing: ${p_trim}" >&2
      fi
    done
  fi

  # Last-commit date for dispatcher.
  disp_date="$(git log -1 --format=%cd --date=short -- "$dispatcher" 2>/dev/null || true)"
  [[ -z "$disp_date" ]] && disp_date="0000-00-00"

  # Last-commit date for sibling folder (recursive).
  sib_date="N/A"
  sib_count=0
  if [[ -d "$sibling" ]]; then
    raw_sib_date="$(git log -1 --format=%cd --date=short -- "$sibling" 2>/dev/null || true)"
    if [[ -n "$raw_sib_date" ]]; then
      sib_date="$raw_sib_date"
    fi
    sib_count=$(find "$sibling" -type f | wc -l | tr -d ' ')
  fi

  # MAX of disp_date and sib_date (lexicographic ISO works).
  max_date="$disp_date"
  if [[ "$sib_date" != "N/A" && "$sib_date" > "$max_date" ]]; then
    max_date="$sib_date"
  fi

  # Online: query issue state.
  issue_state="unknown"
  if [[ "$OFFLINE" -eq 0 && "$GH_OK" -eq 1 ]]; then
    raw_state="$(gh api "repos/${REPO_SLUG}/issues/${issue_num}" --jq .state 2>/dev/null || true)"
    if [[ -n "$raw_state" ]]; then
      issue_state="$(echo "$raw_state" | tr '[:upper:]' '[:lower:]')"
    fi
  fi

  # Offline: skip emission.
  if [[ "$OFFLINE" -eq 1 ]]; then
    continue
  fi

  # Filter: issue must be closed.
  if [[ "$issue_state" != "closed" ]]; then
    continue
  fi

  # Filter: last-commit must be older than cutoff.
  if [[ ! "$max_date" < "$CUTOFF_DATE" ]]; then
    continue
  fi

  CANDIDATES+=("$dispatcher")

  if [[ "$FORMAT" == "text" ]]; then
    echo "CANDIDATE: ${dispatcher}"
    echo "  Issue: #${issue_num} (${issue_state})"
    if [[ -d "$sibling" ]]; then
      echo "  Last-commit: ${max_date} (dispatcher: ${disp_date} | sibling: ${sib_date})"
      echo "  Sibling folder: ${sibling}/ (${sib_count} files)"
      echo "  Deletion unit: ${dispatcher} ${sibling}/"
    else
      echo "  Last-commit: ${max_date} (dispatcher: ${disp_date} | sibling: N/A)"
      echo "  Sibling folder: (none)"
      echo "  Deletion unit: ${dispatcher}"
    fi
    echo ""
  else
    sib_field="null"
    if [[ -d "$sibling" ]]; then
      sib_field="\"${sibling}/\""
    fi
    JSON_ITEMS+=("{\"dispatcher\":\"${dispatcher}\",\"issue\":${issue_num},\"state\":\"${issue_state}\",\"last_commit\":\"${max_date}\",\"dispatcher_date\":\"${disp_date}\",\"sibling_date\":\"${sib_date}\",\"sibling\":${sib_field},\"sibling_file_count\":${sib_count}}")
  fi
done

if [[ "$FORMAT" == "json" ]]; then
  printf '{"generated":"%s","cutoff":"%s","stale_months":%s,"offline":%s,"candidates":[' \
    "$TODAY" "$CUTOFF_DATE" "$STALE_MONTHS" "$([[ $OFFLINE -eq 1 ]] && echo true || echo false)"
  first=1
  for item in "${JSON_ITEMS[@]}"; do
    if [[ "$first" -eq 1 ]]; then
      first=0
    else
      printf ','
    fi
    printf '%s' "$item"
  done
  printf ']}\n'
fi

if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
  exit 1
fi
exit 0
