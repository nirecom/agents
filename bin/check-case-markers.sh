#!/usr/bin/env bash
# Detect test files that cover multiple # Tests: paths but have no case_begin/case_end markers.
# Usage: check-case-markers.sh <file1> [file2 ...]
# Prints: HIGH: <file> (N paths in # Tests: header, no case_begin/case_end) for each violation.
# Exit 0: no violations. Exit 1: one or more violations found.
set -euo pipefail

violations=0
for file in "$@"; do
  [[ -f "$file" ]] || continue

  # Extract the # Tests: line from the header (first 10 lines).
  tests_line=$(head -n 10 "$file" | grep "^# Tests:" | head -n 1 || true)
  [[ -z "$tests_line" ]] && continue

  # Count comma-separated paths: commas + 1.
  no_commas="${tests_line//,/}"
  path_count=$(( ${#tests_line} - ${#no_commas} + 1 ))
  [[ "$path_count" -lt 2 ]] && continue

  # case_begin anywhere in the file (including fixture heredocs) satisfies the check.
  if grep -q "case_begin" "$file" 2>/dev/null; then
    continue
  fi

  echo "HIGH: $file ($path_count paths in # Tests: header, no case_begin/case_end markers)"
  violations=1
done

exit "$violations"
