#!/usr/bin/env bash
# Check case_begin/case_end marker placement in test files that cover multiple
# # Tests: paths. The verdict is the retire parser's (trp_marker_conformance), so
# a marker the gate accepts is one retire can split cases on (CPR-SSOT).
# Usage: check-case-markers.sh <file1> [file2 ...]   (file paths only)
# Prints, per file:
#   HIGH: <file> (N paths in # Tests: header, no case_begin/case_end markers) code=MISSING_CASE_MARKERS
#   HIGH: <file> line <L>: malformed case marker (<reason>) code=MALFORMED_CASE_MARKER
#   WARN: <file> line <L>: case marker nesting uncertain (...) code=UNCERTAIN_CASE_MARKER
# Exit 0: no HIGH (WARN lines allowed). Exit 1: HIGH found, no arguments, or a
# non-existent path (stderr). Exit 2: predicate library unavailable (infra error).
set -euo pipefail

_ccm_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-retire-predicate.sh"
# shellcheck source=lib/test-retire-predicate.sh
if [[ ! -f "$_ccm_lib" ]] || ! source "$_ccm_lib" 2>/dev/null \
   || ! declare -F trp_marker_conformance >/dev/null; then
  echo "check-case-markers.sh: predicate library unavailable" >&2
  exit 2
fi

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

  # Extract the Tests: line from the header (registry headerMaxLines, entry comment prefix).
  tests_line=$(head -n "$TLR_HEADER_MAX_LINES" "$file" | awk -v p="$(tlr_comment_prefix "$file") Tests:" 'index($0, p) == 1 { print; exit }' || true)
  [[ -z "$tests_line" ]] && continue

  # Count comma-separated paths: commas + 1. A single path retires at file
  # granularity anyway, so markers add nothing there.
  no_commas="${tests_line//,/}"
  path_count=$(( ${#tests_line} - ${#no_commas} + 1 ))
  [[ "$path_count" -lt 2 ]] && continue

  trp_marker_conformance "$file"
  case "$TRP_MARKER_STATE" in
    none)
      echo "HIGH: $file ($path_count paths in # Tests: header, no case_begin/case_end markers) code=MISSING_CASE_MARKERS"
      violations=1 ;;
    malformed)
      echo "HIGH: $file line $TRP_MARKER_LINE: malformed case marker ($TRP_MARKER_REASON) code=MALFORMED_CASE_MARKER"
      violations=1 ;;
    uncertain)
      echo "WARN: $file line $TRP_MARKER_LINE: case marker nesting uncertain (multi-line quoted string before the marker; use a heredoc so retire can split cases) code=UNCERTAIN_CASE_MARKER" ;;
    *) ;;
  esac
done

exit "$violations"
