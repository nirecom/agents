#!/usr/bin/env bash
# Check case-marker placement in test files that cover multiple Tests: paths. The verdict is the
# FILE line of crr_read, so each language's reader part decides it and a marker the gate accepts
# is one retire can split cases on (CPR-SSOT). Marker wording comes from the registry entry.
# Usage: check-case-markers.sh <file1> [file2 ...]   (file paths only)
# Prints HIGH: ... code=MISSING_CASE_MARKERS | MALFORMED_CASE_MARKER and
# WARN: ... code=UNCERTAIN_CASE_MARKER | CASE_MARKER_RUNTIME_UNAVAILABLE, one line per file.
# Exit 0: no HIGH (WARN lines allowed). Exit 1: HIGH found, no arguments, or a non-existent
# path (stderr). Exit 2: predicate library or a reader part unavailable (infra error).
set -euo pipefail

_ccm_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/test-retire-predicate.sh
if [[ ! -f "$_ccm_lib/test-retire-predicate.sh" ]] || ! source "$_ccm_lib/test-retire-predicate.sh" 2>/dev/null \
   || ! declare -F trp_marker_conformance >/dev/null; then
  echo "check-case-markers.sh: predicate library unavailable" >&2
  exit 2
fi
# shellcheck source=lib/case-record-reader.sh
if [[ ! -f "$_ccm_lib/case-record-reader.sh" ]] || ! source "$_ccm_lib/case-record-reader.sh" 2>/dev/null \
   || ! declare -F crr_read >/dev/null; then
  echo "check-case-markers.sh: predicate library unavailable" >&2
  exit 2
fi

if [[ "$#" -eq 0 ]]; then
  echo "Usage: check-case-markers.sh <file1> [file2 ...]" >&2
  exit 1
fi

tab=$'\t'
violations=0
reader_failed=0
for file in "$@"; do
  if [[ ! -f "$file" ]]; then
    echo "check-case-markers.sh: file not found: $file" >&2
    exit 1
  fi

  # Extract the Tests: line from the header (registry headerMaxLines, entry comment prefix).
  prefix="$(tlr_comment_prefix "$file")"
  tests_line=$(head -n "$TLR_HEADER_MAX_LINES" "$file" | awk -v p="$prefix Tests:" 'index($0, p) == 1 { print; exit }' || true)
  [[ -z "$tests_line" ]] && continue

  # Count comma-separated paths: commas + 1. A single path retires at file
  # granularity anyway, so markers add nothing there.
  no_commas="${tests_line//,/}"
  path_count=$(( ${#tests_line} - ${#no_commas} + 1 ))
  [[ "$path_count" -lt 2 ]] && continue

  record="$(crr_read "$file" || true)"
  record="${record%%$'\n'*}"
  rest="${record#*"$tab"}"; state="${rest%%"$tab"*}"
  rest="${rest#*"$tab"}"; marker_line="${rest%%"$tab"*}"; reason="${rest#*"$tab"}"
  lang_id=""
  if tlr_match "$file"; then lang_id="$TLR_ID"; fi
  [[ "$state" == malformed && "$reason" == reader ]] && state=reader-failed
  case "$state" in
    none)
      _tlr_get "$lang_id" diagnostics.markerName || _TLR_V="case"
      echo "HIGH: $file ($path_count paths in $prefix Tests: header, no $_TLR_V markers) code=MISSING_CASE_MARKERS"
      violations=1 ;;
    malformed)
      echo "HIGH: $file line $marker_line: malformed case marker ($reason) code=MALFORMED_CASE_MARKER"
      violations=1 ;;
    uncertain)
      hint=""
      if _tlr_get "$lang_id" diagnostics.markerUncertainHint; then hint=" ($_TLR_V)"; fi
      echo "WARN: $file line $marker_line: case marker nesting uncertain$hint code=UNCERTAIN_CASE_MARKER" ;;
    unavailable)
      echo "WARN: $file: case markers not checked ($reason is not installed) code=CASE_MARKER_RUNTIME_UNAVAILABLE" ;;
    conforming | unsupported) ;;
    *)
      echo "check-case-markers.sh: case-marker reader unavailable: $file" >&2
      reader_failed=1 ;;
  esac
done

[[ "$violations" -eq 1 ]] && exit 1
[[ "$reader_failed" -eq 1 ]] && exit 2
exit 0
