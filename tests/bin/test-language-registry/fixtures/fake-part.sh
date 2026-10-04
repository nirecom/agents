# Fixture parts for the fake-part entry (copied to bin/lib/test-language-parts/ of a
# fixture checkout). Source-only. Each stub records that it ran, then returns a fixed result.
# shellcheck shell=bash

# fake_read_markers <abs> — a fixed one-case result in the case-marker reader contract.
fake_read_markers() {
  FAKE_READER_ARG="$1"
  TRP_CASE_BEGIN_LINES=(3); TRP_CASE_END_LINES=(5)
  TRP_CASE_TARGETS=("bin/check-table-driven.sh"); TRP_CASE_NAMES=("fake-case")
  TRP_CASE_COUNT=1; TRP_HAS_MARKERS=1
  _TRP_MARKER_MALFORMED=0; _TRP_MARKER_MALFORMED_LINE=""
  _TRP_MARKER_MALFORMED_REASON=""; _TRP_MARKER_UNCERTAIN=0
}

# fake_is_table_driven <path> — rc 0 when the file carries the FAKE_TABLE token.
fake_is_table_driven() {
  grep -q 'FAKE_TABLE' "$1" 2>/dev/null
}
