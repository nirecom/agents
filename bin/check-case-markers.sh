#!/usr/bin/env bash
# Detect test files that cover multiple # Tests: paths but have no case_begin/case_end markers.
# Usage: check-case-markers.sh <file1> [file2 ...]
# Prints: HIGH: <file> (N paths in # Tests: header, no case_begin/case_end) for each violation.
# Exit 1: violations found, no arguments, or a non-existent path (message on stderr).
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  echo "Usage: check-case-markers.sh <file1> [file2 ...]" >&2
  exit 1
fi

violations=0
for file in "$@"; do
  if [[ ! -f "$file" ]]; then
    echo "check-case-markers.sh: file not found: $file" >&2
    exit 1
  fi

  # Extract the # Tests: line from the header (first 10 lines).
  tests_line=$(head -n 10 "$file" | grep "^# Tests:" | head -n 1 || true)
  [[ -z "$tests_line" ]] && continue

  # Count comma-separated paths: commas + 1.
  no_commas="${tests_line//,/}"
  path_count=$(( ${#tests_line} - ${#no_commas} + 1 ))
  [[ "$path_count" -lt 2 ]] && continue

  # case_begin call (anchored: ^[[:space:]]*case_begin[[:space:]]+") satisfies the check.
  # Matches invocations inside fixture heredocs but not function definitions like case_begin().
  if grep -Eq '^[[:space:]]*case_begin[[:space:]]+"' "$file" 2>/dev/null; then
    continue
  fi

  echo "HIGH: $file ($path_count paths in # Tests: header, no case_begin/case_end markers)"
  violations=1
done

exit "$violations"
