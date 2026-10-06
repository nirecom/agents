#!/usr/bin/env bash
# tests/bin/bin-run-all-duration-counts.sh
# Tests: bin/lib/run-all-duration-counts.sh, bin/lib/run-all-durations.sh
# Tags: run-all, duration-ledger, ledger, sweep-tests, embed-cases, frequency-order, TL2, scope:common
# TL3 gap (what this test does NOT catch):
# - a real ledger grown by months of run-all invocations rather than planted segments
# - an awk other than this host's (the POSIX subset is assumed, not proven)
# Closest-to-action mitigation: none needed — a read-only ordering heuristic, no risk category.
set -uo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$AGENTS_DIR/tests/lib/harness.sh"

ROOT="$(make_tmp)"
trap 'rm -rf "$ROOT"' EXIT
harness_isolate "$ROOT/iso"
export HOME="$ROOT/home" NO_LOG=true RUN_ALL_CACHE_DIR="$ROOT/cache"
mkdir -p "$HOME" "$RUN_ALL_CACHE_DIR"

PAR_LIB="$AGENTS_DIR/bin/lib/run-all-parallelism.sh"
DUR_LIB="$AGENTS_DIR/bin/lib/run-all-durations.sh"
CNT_REL="bin/lib/run-all-duration-counts.sh"
. "$PAR_LIB"
. "$DUR_LIB"
[ -f "$AGENTS_DIR/$CNT_REL" ] && . "$AGENTS_DIR/$CNT_REL"

REPO="$ROOT/repo"
harness_git_init "$REPO"
cd "$REPO" || exit 1
# Primed AFTER every source: the counts lib reuses the memoised identity of the repo under test.
run_all_dur_repo_id "$REPO" >/dev/null
run_all_dur_host_token >/dev/null
RID="$RUN_ALL_DUR_REPO_ID"
TOK="$RUN_ALL_DUR_HOST_TOKEN"
OTHER_RID="$(run_all_dur_pad16 "foreignrepo${RID}")"
OTHER_TOK="$(run_all_dur_pad16 "foreignhost${TOK}")"
LEDGER="$(run_all_dur_dir)"
MAX_SEG="$RUN_ALL_DUR_MAX_SEGMENTS_READ"
MAX_REC="$RUN_ALL_DUR_MAX_RECORDS"
OUT="$ROOT/counts.tsv"

seg() { printf '%s/dur.%s.%s.20200101T%06d-1.log\n' "$LEDGER" "$RUN_ALL_DUR_SCHEMA" "${2:-$TOK}" "$1"; }
fresh() { rm -rf "$LEDGER"; mkdir -p "$LEDGER"; }
# rec <file> <rid> <key>... — one documented `repo_id|secs|key` record per key.
rec() {
  local f="$1" r="$2" k
  shift 2
  for k in "$@"; do printf '%s|1|%s\n' "$r" "$k" >>"$f"; done
}

counts_ready() {
  declare -F run_all_dur_counts >/dev/null && return 0
  fail "$1" "run_all_dur_counts is not defined (not implemented: $CNT_REL)"
  return 1
}
# run_counts <total-tests> — RC and GOT ("key=count" sorted, space-joined) from a fresh out file.
run_counts() {
  rm -f "$OUT"
  run_all_dur_counts "$1" "$OUT"
  RC=$?
  GOT="$(awk -F'\t' 'NF { sub(/\r$/, "", $2); print $1 "=" $2 }' "$OUT" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
  GOT="${GOT% }"
}

expect_counts() {
  local name="$1" want="$2"
  if [ "$RC" -eq 0 ] && [ "$GOT" = "$want" ]; then
    pass "$name"
  else
    fail "$name" "want rc=0 '$want', got rc=$RC '$GOT'"
  fi
}

case_begin "counts-segments-not-lines" "bin/lib/run-all-duration-counts.sh"
if counts_ready "counts-segments-not-lines"; then
  fresh
  rec "$(seg 1)" "$RID" a.sh b.sh
  rec "$(seg 2)" "$RID" a.sh a.sh c.sh
  rec "$(seg 3)" "$RID" a.sh
  run_counts 100
  expect_counts "counts-segments-not-lines: a key repeated inside one segment counts once" "a.sh=3 b.sh=1 c.sh=1"
fi
case_end

case_begin "full-run-threshold-at-exactly-half" "bin/lib/run-all-duration-counts.sh"
if counts_ready "full-run-threshold-at-exactly-half"; then
  fresh
  rec "$(seg 1)" "$RID" k1 k2 k3 k4
  rec "$(seg 2)" "$RID" k1 k2 k3 k4 k5
  run_counts 10
  expect_counts "full-run-threshold-at-exactly-half: 4/10 kept, 5/10 excluded" "k1=1 k2=1 k3=1 k4=1"
fi
case_end

case_begin "full-run-threshold-odd-total" "bin/lib/run-all-duration-counts.sh"
if counts_ready "full-run-threshold-odd-total"; then
  fresh
  rec "$(seg 1)" "$RID" k1 k2 k3 k4
  rec "$(seg 2)" "$RID" x1 x2 x3 x4 x5
  run_counts 9
  expect_counts "full-run-threshold-odd-total: 4/9 is under half (kept), 5/9 is over (excluded)" "k1=1 k2=1 k3=1 k4=1"
fi
case_end

case_begin "threshold-uses-distinct-keys" "bin/lib/run-all-duration-counts.sh"
if counts_ready "threshold-uses-distinct-keys"; then
  fresh
  rec "$(seg 1)" "$RID" k1 k1 k1 k1 k1 k1 k2
  run_counts 10
  expect_counts "threshold-uses-distinct-keys: 7 lines but 2 distinct keys stay under half of 10" "k1=1 k2=1"
fi
case_end

case_begin "foreign-repo-records-ignored" "bin/lib/run-all-duration-counts.sh"
if counts_ready "foreign-repo-records-ignored"; then
  fresh
  rec "$(seg 1)" "$RID" k1 k2 k3 k4
  rec "$(seg 1)" "$OTHER_RID" f1 f2 f3
  run_counts 10
  expect_counts "foreign-repo-records-ignored: neither counted nor added to the full-run threshold" "k1=1 k2=1 k3=1 k4=1"
fi
case_end

case_begin "foreign-host-segment-ignored" "bin/lib/run-all-duration-counts.sh"
if counts_ready "foreign-host-segment-ignored"; then
  fresh
  rec "$(seg 1)" "$RID" k1
  rec "$(seg 2 "$OTHER_TOK")" "$RID" h1 k1
  run_counts 100
  expect_counts "foreign-host-segment-ignored: another host token's segment is never read" "k1=1"
fi
case_end

case_begin "pipeless-lines-ignored" "bin/lib/run-all-duration-counts.sh"
if counts_ready "pipeless-lines-ignored"; then
  fresh
  printf 'not a record\n\nanother bare line\n' >"$(seg 1)"
  rec "$(seg 1)" "$RID" k1
  run_counts 4
  expect_counts "pipeless-lines-ignored: bare lines are no key and do not push the segment over half of 4" "k1=1"
fi
case_end

case_begin "no-ledger-dir-is-empty" "bin/lib/run-all-duration-counts.sh"
if counts_ready "no-ledger-dir-is-empty"; then
  rm -rf "$LEDGER"
  run_counts 10
  if [ "$RC" -eq 0 ] && [ ! -s "$OUT" ] && [ ! -e "$LEDGER" ]; then
    pass "no-ledger-dir-is-empty: rc 0, empty output, ledger dir not created"
  else
    fail "no-ledger-dir-is-empty" "rc=$RC out='$GOT' ledger-created=$([ -e "$LEDGER" ] && echo yes || echo no)"
  fi
fi
case_end

case_begin "segment-read-cap" "bin/lib/run-all-duration-counts.sh"
if counts_ready "segment-read-cap"; then
  fresh
  TOTAL_SEG=$((MAX_SEG + 2))
  i=1
  while [ "$i" -le "$TOTAL_SEG" ]; do rec "$(seg "$i")" "$RID" "filler/$i"; i=$((i + 1)); done
  rec "$(seg $((TOTAL_SEG - MAX_SEG + 1)))" "$RID" edge/in
  rec "$(seg $((TOTAL_SEG - MAX_SEG)))" "$RID" edge/out
  run_counts $((MAX_SEG * 1000))
  case " $GOT " in
    *" edge/in=1 "*" filler/$TOTAL_SEG=1 "*)
      case " $GOT " in
        *" edge/out="*|*" filler/1="*) fail "segment-read-cap" "a segment past RUN_ALL_DUR_MAX_SEGMENTS_READ=$MAX_SEG was counted: $GOT" ;;
        *) pass "segment-read-cap: the newest $MAX_SEG of $TOTAL_SEG segments were counted, older ones not" ;;
      esac ;;
    *) fail "segment-read-cap" "want edge/in=1 and filler/$TOTAL_SEG=1, got rc=$RC '$GOT'" ;;
  esac
fi
case_end

case_begin "record-cap" "bin/lib/run-all-duration-counts.sh"
if counts_ready "record-cap"; then
  fresh
  rec "$(seg 1)" "$RID" beyond/cutoff.sh
  awk -v n=$((MAX_REC + 50)) -v rid="$RID" 'BEGIN { for (i = 0; i < n; i++) printf "%s|1|pad/%d.sh\n", rid, i }' >"$(seg 2)"
  run_counts $((MAX_REC * 10))
  case " $GOT " in
    *" beyond/cutoff.sh="*) fail "record-cap" "a key reachable only past RUN_ALL_DUR_MAX_RECORDS=$MAX_REC was counted" ;;
    *" pad/0.sh=1 "*) pass "record-cap: the newest segment was read up to the record cap and the older one never" ;;
    *) fail "record-cap" "want pad/0.sh=1 from the newest segment, got rc=$RC (${#GOT} bytes of output)" ;;
  esac
fi
case_end

case_begin "writer-segments-counted" "bin/lib/run-all-duration-counts.sh"
if counts_ready "writer-segments-counted"; then
  fresh
  W='. "$1"; . "$2"; run_all_dur_writer_init "$3"; shift 3; for k in "$@"; do run_all_dur_append "$k" 2; done'
  bash -c "$W" _ "$PAR_LIB" "$DUR_LIB" "$REPO" w/a.sh w/b.sh
  bash -c "$W" _ "$PAR_LIB" "$DUR_LIB" "$REPO" w/a.sh
  run_counts 100
  expect_counts "writer-segments-counted: two real writer processes give two segments" "w/a.sh=2 w/b.sh=1"
fi
case_end

case_begin "read-only-and-idempotent" "bin/lib/run-all-duration-counts.sh"
if counts_ready "read-only-and-idempotent"; then
  fresh
  rec "$(seg 1)" "$RID" k1 k2
  rec "$(seg 2)" "$RID" k1
  BEFORE="$(ls -l "$LEDGER" | cksum)"
  run_counts 100
  FIRST="$GOT"
  run_counts 100
  if [ "$RC" -eq 0 ] && [ "$GOT" = "$FIRST" ] && [ "$GOT" = "k1=2 k2=1" ] && [ "$(ls -l "$LEDGER" | cksum)" = "$BEFORE" ]; then
    pass "read-only-and-idempotent: same counts twice, ledger untouched"
  else
    fail "read-only-and-idempotent" "first='$FIRST' second='$GOT' rc=$RC"
  fi
fi
case_end

case_begin "hostile-key-is-data" "bin/lib/run-all-duration-counts.sh"
if counts_ready "hostile-key-is-data"; then
  fresh
  MARK="$ROOT/pwned"
  EVIL='$(touch '"$MARK"')`touch '"$MARK"'`;evil.sh'
  rec "$(seg 1)" "$RID" "$EVIL"
  run_counts 100
  if [ "$RC" -eq 0 ] && [ ! -e "$MARK" ] && [ "$GOT" = "$EVIL=1" ]; then
    pass "hostile-key-is-data: the metacharacter key is counted verbatim and never executed"
  else
    fail "hostile-key-is-data" "rc=$RC marker=$([ -e "$MARK" ] && echo created || echo absent) got='$GOT'"
  fi
fi
case_end

# The fixture for the extraction cases: more own segments than the cap, plus look-alikes.
plant_lookalikes() {
  fresh
  local i=1
  while [ "$i" -le $((MAX_SEG + 3)) ]; do rec "$(seg "$i")" "$RID" "filler/$i"; i=$((i + 1)); done
  rec "$(seg 1)" "$RID" edge/out
  rec "$(seg $((MAX_SEG + 3)))" "$RID" edge/newest
  printf '%s|9|edge/newest\n' "$RID" >"$(seg 9999 "$OTHER_TOK")"
  printf '%s|9|edge/newest\n' "$RID" >"$LEDGER/dur.$((RUN_ALL_DUR_SCHEMA + 1)).$TOK.20200101T999999-1.log"
  mkdir -p "$LEDGER/dur.$RUN_ALL_DUR_SCHEMA.$TOK.29991231T000000-1.log"
  printf '%s|9|edge/newest\n' "$RID" >"$LEDGER/dur.$RUN_ALL_DUR_SCHEMA.$TOK.20200101T999999-1.txt"
}
# want_segment_names — the newest MAX_SEG own segment basenames, newest first.
want_segment_names() {
  local i=$((MAX_SEG + 3)) stop=3
  while [ "$i" -gt "$stop" ]; do seg "$i"; i=$((i - 1)); done | sed 's#.*/##' | tr '\n' ' '
}

case_begin "segments-into-matches-reader" "bin/lib/run-all-durations.sh"
if ! declare -F run_all_dur_segments_into >/dev/null; then
  fail "segments-into-matches-reader" "run_all_dur_segments_into is not defined (extraction not implemented in bin/lib/run-all-durations.sh)"
else
  plant_lookalikes
  run_all_dur_segments_into "$LEDGER" "$TOK"
  RC=$?
  GOT_SEGS=""
  if declare -p RUN_ALL_DUR_SEGMENTS_OUT >/dev/null 2>&1; then
    for f in "${RUN_ALL_DUR_SEGMENTS_OUT[@]}"; do GOT_SEGS="$GOT_SEGS${f##*/} "; done
  fi
  WANT_SEGS="$(want_segment_names)"
  printf 'k1\tedge/newest\nk2\tedge/out\n' >"$ROOT/keys.tsv"
  run_all_dur_lookup "$REPO" "$ROOT/keys.tsv" "$ROOT/lookup.out"
  if [ "$RC" -eq 0 ] && [ "$GOT_SEGS" = "$WANT_SEGS" ] && [ "$RUN_ALL_DUR_SEGMENTS_READ" = "$MAX_SEG" ]; then
    pass "segments-into-matches-reader: newest $MAX_SEG own segments, newest first; look-alikes excluded; lookup read the same count"
  else
    fail "segments-into-matches-reader" "rc=$RC read=$RUN_ALL_DUR_SEGMENTS_READ want='$WANT_SEGS' got='$GOT_SEGS'"
  fi
fi
case_end

case_begin "segments-into-missing-dir" "bin/lib/run-all-durations.sh"
if ! declare -F run_all_dur_segments_into >/dev/null; then
  fail "segments-into-missing-dir" "run_all_dur_segments_into is not defined (extraction not implemented in bin/lib/run-all-durations.sh)"
else
  RUN_ALL_DUR_SEGMENTS_OUT=(stale-entry)
  run_all_dur_segments_into "$ROOT/no-such-dir" "$TOK"
  RC=$?
  if [ "$RC" -eq 0 ] && [ "${#RUN_ALL_DUR_SEGMENTS_OUT[@]}" -eq 0 ]; then
    pass "segments-into-missing-dir: rc 0 and an emptied list (no stale entry survives)"
  else
    fail "segments-into-missing-dir" "rc=$RC entries=${#RUN_ALL_DUR_SEGMENTS_OUT[@]}"
  fi
fi
case_end

case_begin "lookup-unchanged-over-lookalikes" "bin/lib/run-all-durations.sh"
plant_lookalikes
printf 'k1\tedge/newest\nk2\tedge/out\nk3\tfiller/4\n' >"$ROOT/keys.tsv"
run_all_dur_lookup "$REPO" "$ROOT/keys.tsv" "$ROOT/lookup.out"
LK="$(tr -d '\r' <"$ROOT/lookup.out" | tr '\t\n' ': ')"
if [ "$LK" = "k1:1 k2: k3:1 " ]; then
  pass "lookup-unchanged-over-lookalikes: newest value wins, past-cap key empty, look-alikes unread"
else
  fail "lookup-unchanged-over-lookalikes" "reason=$RUN_ALL_DUR_REASON got='$LK'"
fi
case_end

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
