# tests/bin/feature-2502-bash-golden/walk.sh
# Tests: bin/lib/case-record-reader.sh
# Tags: TL2, case-markers, golden, scope:issue-specific
# Run as `bash walk.sh <checkout> <out-dir> <relpath>...` from record.sh (gb_record_all): a fresh bash
# that sourced only the checkout's case-record-reader.sh walks every input in one shell, the way
# the sweep does, and writes crr-read.tsv, embed-ops.tsv, enumerate-cases.tsv and
# remove-orphan.tsv into <out-dir>. Never sourced by a test.
co="$1" out="$2"
shift 2
cd "$co" || exit 97
# shellcheck source=../../../bin/lib/case-record-reader.sh
. "$co/bin/lib/case-record-reader.sh" || exit 97
tab=$'\t'
: >"$out/crr-read.tsv"
: >"$out/embed-ops.tsv"
: >"$out/enumerate-cases.tsv"
: >"$out/remove-orphan.tsv"

row() {
  local IFS="$tab"
  printf '%s\n' "$*"
}
csv() {
  local IFS=,
  printf '%s' "$*"
}
# rows <prefix...> — one row per line of stdin, each led by the prefix fields.
rows() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do row "$@" "$line"; done
}

# read_and_ops <rel> — crr_read, then the four bash caseEmbedRules ops in the same shell.
read_and_ops() {
  local rel="$1" abs="$co/$1" o rc res
  crr_read "$abs" >"$out/.crr"
  rows "$rel" <"$out/.crr" >>"$out/crr-read.tsv"
  for o in deps leftover-defs self-impl skip-reason; do
    rc=0
    res="$(tlr_call_part bash caseEmbedRules "$o" "$abs" 2>/dev/null)" || rc=$?
    row "$rel" "$o" "rc=$rc"
    [ -z "$res" ] || printf '%s\n' "$res" | rows "$rel" "$o"
  done >>"$out/embed-ops.tsv"
}

# enumerate <rel> — the trp_enumerate_cases globals for one file.
enumerate() {
  TRP_MARKER_STATE=""
  trp_enumerate_cases "$co" "$1"
  row "$1" "state=$TRP_MARKER_STATE" "has=$TRP_HAS_MARKERS" "count=$TRP_CASE_COUNT" \
    "malformed=$_TRP_MARKER_MALFORMED" "line=$_TRP_MARKER_MALFORMED_LINE" "reason=$_TRP_MARKER_MALFORMED_REASON" \
    "uncertain=$_TRP_MARKER_UNCERTAIN" "names=$(csv "${TRP_CASE_NAMES[@]}")" "targets=$(csv "${TRP_CASE_TARGETS[@]}")" \
    "begin=$(csv "${TRP_CASE_BEGIN_LINES[@]}")" "end=$(csv "${TRP_CASE_END_LINES[@]}")" \
    "alive=$(csv "${TRP_CASE_ALIVE[@]}")" "orphan=$(csv "${TRP_ORPHAN_CASE_IDX[@]}")" "refcount=$TRP_REFCOUNT" \
    >>"$out/enumerate-cases.tsv"
}

# remove <rel> — for a file with an orphan case: the verdict, then the removal on a staged copy.
remove() {
  local rel="$1" copy="tests/rm/${1//\//__}" rc=0 names
  [ "${#TRP_ORPHAN_CASE_IDX[@]}" -gt 0 ] || return 0
  mkdir -p "$co/tests/rm"
  cp "$co/$rel" "$co/$copy"
  git -C "$co" add -- "$copy" >/dev/null 2>&1
  trp_case_refcount_verdict "$co" "$copy" >/dev/null 2>&1
  names="$(trp_remove_orphan_cases "$co" "$copy" 2>/dev/null)" || rc=$?
  {
    row "$rel" "verdict=$TRP_VERDICT" "unit=$TRP_UNIT_MODE" "rc=$rc" "removed=$(printf '%s' "$names" | tr '\n' ',')"
    awk '{ printf "%d\t%s\n", NR, $0 }' "$co/$copy" | rows "$rel" body
  } >>"$out/remove-orphan.tsv"
}

for rel in "$@"; do
  read_and_ops "$rel"
  enumerate "$rel"
  remove "$rel"
done
rm -f "$out/.crr"
