#!/usr/bin/env bash
# tests/lib/harness-detail.sh
# Tests: tests/lib/harness-detail.sh
# Tags: scope:common, shared-lib, fail-details
# Sourced by tests/lib/harness.sh (#2956). fail() writes one fail-details.tsv record per call,
# <seq>\t<case>\t<text>, with seq 0 / case "-" outside a case. The fold of <text> and the list /
# count markers: docs/architecture/claude-code/test-result-contract.md (fail-details.tsv section).

_HARNESS_DETAIL_MAX=8192

# _harness_detail_fold <text> — _HARNESS_DETAIL_OUT = <text> folded to one line.
_harness_detail_fold() {
  local LC_ALL=C s="$1" rest line out=""
  s="${s//$'\r\n'/$'\n'}"
  s="${s//$'\r'/$'\n'}"
  rest="$s"
  while :; do
    line="${rest%%$'\n'*}"
    line="${line%"${line##*[!$' \t']}"}"
    out+="$line"
    [[ "$rest" == *$'\n'* ]] || break
    out+=$'\n'
    rest="${rest#*$'\n'}"
  done
  while [[ "$out" == *$'\n' ]]; do out="${out%$'\n'}"; done
  out="${out//\\/\\\\}"
  out="${out//$'\t'/\\t}"
  out="${out//$'\n'/\\n}"
  if [ "${#out}" -gt "$_HARNESS_DETAIL_MAX" ]; then
    out="${out:0:$_HARNESS_DETAIL_MAX}\\n[cut]"
  fi
  _HARNESS_DETAIL_OUT="$out"
}

# _harness_detail_record <text> — the fail-details.tsv record of one fail(); a no-op without a result dir.
_harness_detail_record() {
  local seq=0 name="-"
  [ -n "${_HARNESS_DETAILS_FILE:-}" ] || return 0
  if [ -n "${_HARNESS_CASE_OPEN:-}" ]; then
    seq="$_HARNESS_CASE_SEQ"
    name="$_HARNESS_CASE_NAME"
  fi
  _harness_detail_fold "$1"
  printf '%s\t%s\t%s\n' "$seq" "$name" "$_HARNESS_DETAIL_OUT" >>"$_HARNESS_DETAILS_FILE" 2>/dev/null || true
}

# harness_count_detail <n> — the count marker: [count=<n>].
harness_count_detail() {
  printf '[count=%s]' "$1"
}

# harness_list_detail <total> <item>... — the list marker; it lists every item only when the
# number of items equals <total>. \ | ] inside an item are backslash-escaped.
harness_list_detail() {
  local total="$1" item sep="" out=""
  shift
  for item in "$@"; do
    item="${item//\\/\\\\}"
    item="${item//|/\\|}"
    item="${item//]/\\]}"
    out+="$sep$item"
    sep=" | "
  done
  printf '[list total=%s: %s]' "$total" "$out"
}
