#!/usr/bin/env bash
# tests/lib/fail-detail-fold.sh
# Tests: tests/lib/fail-detail-fold.sh
# Tags: scope:common, shared-lib, fail-details
# Reader of tests/fixtures/fail-detail-fold.tsv (#2956 S3): the one input/expected table every
# fail-details.tsv writer test (bash harness, pytest, node, Pester) checks its fold against.
# Source after tests/lib/harness.sh (pass/fail); it finds its fixture from its own location.

FOLD_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures" && pwd)/fail-detail-fold.tsv"
FOLD_NAMES=()
FOLD_INPUTS=()
FOLD_WANTS=()

# _fold_expand <text> — FOLD_X = <text> with every @@REP:<n>:<c>@@ expanded.
_fold_expand() {
  local s="$1" out="" pre rest n c rep
  while [[ "$s" == *@@REP:* ]]; do
    pre="${s%%@@REP:*}"
    rest="${s#*@@REP:}"
    n="${rest%%:*}"
    rest="${rest#*:}"
    c="${rest:0:1}"
    rest="${rest:3}"
    printf -v rep '%*s' "$n" ''
    out+="$pre${rep// /$c}"
    s="$rest"
  done
  FOLD_X="$out$s"
}

# fold_load — fills FOLD_NAMES / FOLD_INPUTS (decoded, expanded) / FOLD_WANTS (expanded).
fold_load() {
  local name in want dec
  FOLD_NAMES=() FOLD_INPUTS=() FOLD_WANTS=()
  while IFS=$'\t' read -r name in want; do
    case "$name" in ''|'#'*) continue ;; esac
    # %b decodes exactly the four escapes the fixture uses (\\ \t \r \n), left to right.
    printf -v dec '%b' "$in"
    _fold_expand "$dec"
    FOLD_INPUTS+=("$FOLD_X")
    _fold_expand "$want"
    FOLD_WANTS+=("$FOLD_X")
    FOLD_NAMES+=("$name")
  done <"$FOLD_FIXTURE"
}

# fold_write_inputs <dir> — <dir>/<idx>.txt holds row idx's decoded input, byte for byte.
fold_write_inputs() {
  local i
  mkdir -p "$1"
  for i in "${!FOLD_INPUTS[@]}"; do
    printf '%s' "${FOLD_INPUTS[$i]}" >"$1/$i.txt"
  done
}

# fold_check_records <fail-details.tsv> <case-prefix> <case-suffix> — per row: exactly one record
# whose case contains <prefix><idx><suffix>, and its text equals the expected fold.
fold_check_records() {
  local tsv="$1" pre="$2" suf="$3" i key n got want
  if [ ! -f "$tsv" ]; then
    fail "fold: fail-details.tsv written" "missing: $tsv"
    return 0
  fi
  for i in "${!FOLD_NAMES[@]}"; do
    key="$pre$i$suf"
    n="$(awk -F'\t' -v c="$key" 'index($2,c)>0{n++} END{print n+0}' "$tsv")"
    if [ "$n" != 1 ]; then
      fail "fold ${FOLD_NAMES[$i]}: one record" "case~$key records=$n"
      continue
    fi
    got="$(awk -F'\t' -v c="$key" 'index($2,c)>0{print $3}' "$tsv")"
    want="${FOLD_WANTS[$i]}"
    if [ "$got" = "$want" ]; then
      pass "fold ${FOLD_NAMES[$i]}"
    else
      fail "fold ${FOLD_NAMES[$i]}" "want(len=${#want})=${want:0:80} got(len=${#got})=${got:0:80}"
    fi
  done
}
