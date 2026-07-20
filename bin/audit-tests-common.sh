#!/usr/bin/env bash
# Detects scope:common test files whose all # Tests: paths are missing.
# Usage: bin/audit-tests-common.sh [--format text|json] [--offline]
# Exit:  0 = orphans found, 1 = no orphans, 2 = error
#
# --offline is accepted for interface symmetry with audit-tests.sh but has no
# effect (orphan detection does not require GitHub API calls).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/test-frontmatter-constants.sh
source "$SCRIPT_DIR/lib/test-frontmatter-constants.sh"
# shellcheck source=lib/test-frontmatter-fix.sh
source "$SCRIPT_DIR/lib/test-frontmatter-fix.sh"

FORMAT="text"
OFFLINE=0
FIX_HEADERS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format) FORMAT="$2"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    --fix-headers) FIX_HEADERS=1; shift ;;
    --apply) echo "ERROR: --apply is not supported by audit-tests-common.sh (deletion requires issue staleness context)" >&2; exit 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: not inside a git repository" >&2
  exit 2
}

if [[ ! -d "$REPO_ROOT/tests" ]]; then
  echo "ERROR: tests/ directory not found in $REPO_ROOT" >&2
  exit 2
fi

TODAY="$(date +%Y-%m-%d)"

orphan_files=()
orphan_tests_csvs=()
orphan_missing_csvs=()

shopt -s nullglob
for testfile in "$REPO_ROOT/tests/"*.sh; do
  base="$(basename "$testfile")"

  # feature-[0-9]*- files are scope:issue-specific — handled by audit-tests.sh
  if [[ "$base" =~ ^feature-[0-9]+- ]]; then
    continue
  fi

  # tests/_archive/ is excluded by the glob (subdirectory), but guard explicitly
  case "$testfile" in
    */tests/_archive/*) continue ;;
  esac

  # --fix-headers mode: report A/B/C token classification per file (no rewrite;
  # deletion is not supported here — CPR-5 symmetry with audit-tests.sh).
  if [[ "$FIX_HEADERS" -eq 1 ]]; then
    ( cd "$REPO_ROOT" && _fix_headers_report "tests/$base" )
    continue
  fi

  tests_header="$(grep -m1 -E '^# Tests:' "$testfile" 2>/dev/null || true)"
  if [[ -z "$tests_header" ]]; then
    # No # Tests: line — cannot determine orphan status; skip
    continue
  fi

  paths_csv="${tests_header#\# Tests:}"
  paths_csv="${paths_csv# }"

  if [[ -z "$paths_csv" ]]; then
    # Empty # Tests: header — skip (cannot determine orphan status)
    continue
  fi

  IFS=',' read -r -a paths_arr <<< "$paths_csv"

  if [[ "${#paths_arr[@]}" -eq 0 ]]; then
    continue
  fi

  all_missing=1
  missing_parts=()
  for p in "${paths_arr[@]}"; do
    p_trim="$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$p_trim" ]] && continue
    if [[ -e "$REPO_ROOT/$p_trim" ]]; then
      all_missing=0
      break
    else
      missing_parts+=("$p_trim")
    fi
  done

  if [[ "$all_missing" -eq 1 && "${#paths_arr[@]}" -gt 0 ]]; then
    orphan_files+=("tests/$base")
    orphan_tests_csvs+=("$paths_csv")
    local_missing="$(IFS=','; echo "${missing_parts[*]:-}")"
    orphan_missing_csvs+=("$local_missing")
  fi
done

# --fix-headers mode reports per-file classification and does not emit orphans.
if [[ "$FIX_HEADERS" -eq 1 ]]; then
  exit 0
fi

if [[ "${#orphan_files[@]}" -eq 0 ]]; then
  if [[ "$FORMAT" == "json" ]]; then
    printf '{"generated":"%s","orphans":[]}\n' "$TODAY"
  fi
  exit 1
fi

if [[ "$FORMAT" == "json" ]]; then
  printf '{"generated":"%s","orphans":[\n' "$TODAY"
  last_idx=$(( ${#orphan_files[@]} - 1 ))
  for i in "${!orphan_files[@]}"; do
    comma=","
    [[ $i -eq $last_idx ]] && comma=""

    IFS=',' read -r -a tp <<< "${orphan_tests_csvs[$i]}"
    IFS=',' read -r -a mp <<< "${orphan_missing_csvs[$i]:-}"

    tests_json="["
    last_tp=$(( ${#tp[@]} - 1 ))
    for j in "${!tp[@]}"; do
      t="$(echo "${tp[$j]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      tc=","
      [[ $j -eq $last_tp ]] && tc=""
      tests_json+="\"$t\"$tc"
    done
    tests_json+="]"

    missing_json="["
    if [[ "${#mp[@]}" -gt 0 && -n "${mp[0]:-}" ]]; then
      last_mp=$(( ${#mp[@]} - 1 ))
      for j in "${!mp[@]}"; do
        m="$(echo "${mp[$j]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$m" ]] && continue
        mc=","
        [[ $j -eq $last_mp ]] && mc=""
        missing_json+="\"$m\"$mc"
      done
    fi
    missing_json+="]"

    printf '  {"file":"%s","tests_paths":%s,"missing_paths":%s}%s\n' \
      "${orphan_files[$i]}" "$tests_json" "$missing_json" "$comma"
  done
  printf ']}\n'
else
  printf '# audit-tests-common.sh report — %s\n' "$TODAY"
  printf '# Criteria: non-feature-NNN tests whose all # Tests: paths are missing\n'
  printf '\n'
  for i in "${!orphan_files[@]}"; do
    printf 'ORPHAN: %s\n' "${orphan_files[$i]}"
    printf '  Tests: %s\n' "${orphan_tests_csvs[$i]}"
    printf '  Missing paths: %s\n' "${orphan_missing_csvs[$i]:-}"
    printf '\n'
  done
fi

exit 0
