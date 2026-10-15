#!/usr/bin/env bash
# Tests: experimental/test-jail/compare-runs.sh, experimental/test-jail/jail-marker.sh
# Tags: scope:issue-specific, tl2, test-jail, fixture-isolation
#
# #2591: compare-runs.sh files a comparison it cannot trust (SAFE-RUN: line in a log, changed rc
# 77, weaker or unverifiable pin, missing result row or requested list) in not-compared.tsv with a
# reason, and never also counts that test as red or green; a valid red still wins (NEW-RED, rc 1).
# Fixtures are small hand-written run dirs (results.tsv with a 4th pin column, logs/, requested.txt).
# It also deletes an existing out dir only when it carries a kind=compare .test-jail-dir marker
# (jail-marker.sh); the run-list.sh side: feature-2591-test-jail-marker.sh.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/state"
unset CLAUDE_CODE_SESSION_ID

. "$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-2591-test-jail/common.sh"
jt_setup || { echo "FAIL: fixture setup"; exit 1; }

TAB=$'\t'
# mk <name> — fresh changed (W) and baseline (B) run dirs.
mk() { W="$TMP_ROOT/$1-changed"; B="$TMP_ROOT/$1-base"; jt_run_dir "$W"; jt_run_dir "$B"; }
# verdict <label> <word> <rc> — the VERDICT line starts with <word>; the exit code matches.
verdict() {
  expect_has "$1: verdict" "$JT_ALL" "VERDICT: $2"
  expect_eq "$1: rc" "$JT_RC" "$3"
}
# nc <label> <test> <reasons...> — the not-compared reasons of one test (one reason, once).
nc() { local l="$1" t="$2"; shift 2; expect_eq "$l: reasons for $t" "$(jt_reasons "$t")" "$* "; }
# untouched <label> <test> — a not-compared test has no summary row and no .w/.b/.new file.
untouched() {
  local base="${2//\//__}"
  expect_eq "$1: no summary row" "$(jt_summary_rows "$2")" ""
  expect_eq "$1: no .w file" "$(have_file "$JT_CMP/$base.w")" "no"
  expect_eq "$1: no .b file" "$(have_file "$JT_CMP/$base.b")" "no"
  expect_eq "$1: no .new file" "$(have_file "$JT_CMP/$base.new")" "no"
}
SAFE="SAFE-RUN: real gh blocked (args: pr list)"
FAILLINE="FAIL: boom"

case_begin "all-green-with-known-pins-is-no-new-red" "experimental/test-jail/compare-runs.sh"
mk c1
jt_add "$W" 0 tests/a.sh full; jt_add "$B" 0 tests/a.sh full
jt_add "$W" 0 tests/b.sh full; jt_add "$B" 0 tests/b.sh full
jt_cmp "$W" "$B"
verdict "all green" NO-NEW-RED 0
expect_eq "all green: nothing not compared" "$(cat "$JT_CMP/not-compared.tsv")" ""
case_end

case_begin "skip-in-changed-is-not-compared" "experimental/test-jail/compare-runs.sh"
mk c2
jt_add "$W" 77 tests/a.sh full; jt_add "$B" 0 tests/a.sh full
jt_cmp "$W" "$B"
nc "changed rc 77" tests/a.sh SKIPPED-IN-CHANGED
untouched "changed rc 77" tests/a.sh
verdict "changed rc 77" INCOMPLETE 3
case_end

case_begin "skip-in-baseline-stays-base-green" "experimental/test-jail/compare-runs.sh"
mk c3
jt_add "$W" 1 tests/a.sh full "" "$FAILLINE"; jt_add "$B" 77 tests/a.sh full
jt_cmp "$W" "$B"
expect_eq "baseline rc 77: class" "$(jt_summary_rows tests/a.sh | cut -f1)" "BASE-GREEN"
verdict "baseline rc 77" NEW-RED 1
case_end

case_begin "safe-run-line-in-either-log-is-not-compared" "experimental/test-jail/compare-runs.sh"
mk c4a
jt_add "$W" 0 tests/a.sh full "" "$SAFE"; jt_add "$B" 0 tests/a.sh full
jt_cmp "$W" "$B"
nc "SAFE-RUN in changed log (rc 0)" tests/a.sh SAFE-RUN-LINE
verdict "SAFE-RUN in changed log" INCOMPLETE 3
mk c4b
jt_add "$W" 0 tests/a.sh full; jt_add "$B" 0 tests/a.sh full "" "$SAFE"
jt_cmp "$W" "$B"
nc "SAFE-RUN in baseline log" tests/a.sh SAFE-RUN-LINE
verdict "SAFE-RUN in baseline log" INCOMPLETE 3
case_end

case_begin "missing-rows-and-requested-list-are-counted" "experimental/test-jail/compare-runs.sh"
mk c5a
jt_add "$W" 0 tests/a.sh full; jt_add "$B" 0 tests/a.sh full
jt_request "$W" tests/x.sh
jt_cmp "$W" "$B"
nc "requested but no changed row" tests/x.sh NO-RESULT-ROW
verdict "no changed row" INCOMPLETE 3
mk c5b
jt_add "$W" 0 tests/a.sh full; jt_add "$B" 0 tests/a.sh full
jt_add "$W" 0 tests/x.sh full
jt_cmp "$W" "$B"
nc "changed row but no baseline row" tests/x.sh NO-RESULT-ROW
verdict "no baseline row" INCOMPLETE 3
mk c5c
jt_add "$W" 0 tests/a.sh full; jt_add "$B" 0 tests/a.sh full
rm -f "$W/requested.txt"
jt_cmp "$W" "$B"
expect_eq "no requested.txt: one counted line" "$(grep -cx "NO-REQUESTED-LIST${TAB}(whole run)" "$JT_CMP/not-compared.tsv")" "1"
verdict "no requested.txt" INCOMPLETE 3
case_end

case_begin "baseline-only-row-is-no-result-row" "experimental/test-jail/compare-runs.sh"
mk c5d
jt_add "$W" 0 tests/a.sh full; jt_add "$B" 0 tests/a.sh full
jt_add "$B" 0 tests/x.sh full
jt_request "$W" tests/x.sh
jt_cmp "$W" "$B"
nc "requested, row only in the baseline" tests/x.sh NO-RESULT-ROW
untouched "requested, row only in the baseline" tests/x.sh
verdict "row only in the baseline" INCOMPLETE 3
case_end

case_begin "new-test-absent-in-baseline-vs-lost-row" "experimental/test-jail/compare-runs.sh"
mk c5e
jt_add "$W" 1 tests/n.sh full "" "$FAILLINE"; echo tests/n.sh >"$B/absent.txt"
jt_cmp "$W" "$B"
expect_eq "red new test: class, baseline rc" "$(jt_summary_rows tests/n.sh | cut -f1,3)" "NEW-TEST${TAB}absent"
expect_eq "red new test: not a lost row" "$(jt_reasons tests/n.sh)" ""
expect_lacks "red new test: not NO-LOG" "$(cat "$JT_CMP/not-compared.tsv")" "NO-LOG"
verdict "red new test" NEW-RED 1
mk c5f
jt_add "$W" 0 tests/n.sh full; echo tests/n.sh >"$B/absent.txt"
jt_cmp "$W" "$B"
expect_eq "green new test: nothing not compared" "$(cat "$JT_CMP/not-compared.tsv")" ""
verdict "green new test" NO-NEW-RED 0
mk c5g
jt_add "$W" 1 tests/n.sh full "" "$FAILLINE"; echo tests/other.sh >"$B/absent.txt"
jt_cmp "$W" "$B"
nc "red lost row (not in absent.txt)" tests/n.sh NO-RESULT-ROW
untouched "red lost row" tests/n.sh
verdict "red lost row" INCOMPLETE 3
case_end

case_begin "weaker-pin-is-not-compared" "experimental/test-jail/compare-runs.sh"
mk c6a
jt_add "$W" 0 tests/a.sh full; jt_add "$B" 0 tests/a.sh state
jt_cmp "$W" "$B"
nc "pin columns differ" tests/a.sh WEAK-PIN
verdict "pin columns differ" INCOMPLETE 3
mk c6b
jt_add "$W" 0 tests/a.sh state "PINNED: obtained=state requested=full fixture"
jt_add "$B" 0 tests/a.sh state "PINNED: obtained=state requested=full fixture"
jt_cmp "$W" "$B"
nc "obtained weaker than requested" tests/a.sh WEAK-PIN
verdict "obtained weaker than requested" INCOMPLETE 3
case_end

case_begin "valid-red-outranks-not-compared" "experimental/test-jail/compare-runs.sh"
mk c7
jt_add "$W" 1 tests/r.sh full "" "$FAILLINE"; jt_add "$B" 0 tests/r.sh full
jt_add "$W" 0 tests/s.sh full "" "$SAFE"; jt_add "$B" 0 tests/s.sh full
jt_cmp "$W" "$B"
expect_eq "valid red: class" "$(jt_summary_rows tests/r.sh | cut -f1)" "BASE-GREEN"
nc "other test" tests/s.sh SAFE-RUN-LINE
verdict "valid red plus not-compared" NEW-RED 1
case_end

case_begin "four-column-rows-and-exact-test-names" "experimental/test-jail/compare-runs.sh"
mk c8
HIT="PINNED: root decoy, command guard or worktree change hit (fixture)"
REAL="PINNED: obtained=full requested=full fixture"
jt_add "$W" 0 tests/a.sh.bak full; jt_add "$B" 0 tests/a.sh.bak full
jt_add "$W" 1 tests/a.sh full "$HIT"$'\n'"$REAL" "$FAILLINE"
jt_add "$B" 1 tests/a.sh full "$HIT"$'\n'"$REAL" "$FAILLINE"
jt_cmp "$W" "$B"
expect_eq "summary row has 7 columns" "$(jt_summary_rows tests/a.sh | awk -F'\t' '{print NF}')" "7"
expect_eq "summary test column is the bare path" "$(awk -F'\t' '$7=="tests/a.sh"{n++} END{print n+0}' "$JT_CMP/summary.tsv")" "1"
expect_eq "baseline rc is a.sh's, not a.sh.bak's" "$(jt_summary_rows tests/a.sh | cut -f3)" "1"
expect_eq "class" "$(jt_summary_rows tests/a.sh | cut -f1)" "SAME-OR-FEWER"
expect_eq "a hit line is not read as the pin: nothing not compared" "$(cat "$JT_CMP/not-compared.tsv")" ""
verdict "four columns" NO-NEW-RED 0
case_end

case_begin "one-reason-per-test-in-order" "experimental/test-jail/compare-runs.sh"
mk c9a
jt_add "$W" 0 tests/a.sh full "" "$SAFE"; jt_add "$B" 0 tests/a.sh state
jt_cmp "$W" "$B"
nc "SAFE-RUN line and weak pin" tests/a.sh SAFE-RUN-LINE
expect_eq "SAFE-RUN line and weak pin: one line" "$(grep -c "${TAB}tests/a.sh\$" "$JT_CMP/not-compared.tsv")" "1"
mk c9b
jt_add "$W" 0 tests/a.sh unknown; jt_add "$B" 0 tests/a.sh state
jt_cmp "$W" "$B"
nc "unknown pin and weak pin" tests/a.sh UNVERIFIED-PIN
mk c9c
jt_add "$W" 77 tests/a.sh full "" "$SAFE"; jt_add "$B" 0 tests/a.sh full
jt_cmp "$W" "$B"
nc "SAFE-RUN line and changed rc 77" tests/a.sh SAFE-RUN-LINE
case_end

case_begin "safe-run-red-is-not-also-red" "experimental/test-jail/compare-runs.sh"
mk c10
jt_add "$W" 1 tests/a.sh full "" "$FAILLINE"$'\n'"$SAFE"; jt_add "$B" 0 tests/a.sh full
jt_cmp "$W" "$B"
nc "red with SAFE-RUN line" tests/a.sh SAFE-RUN-LINE
untouched "red with SAFE-RUN line" tests/a.sh
verdict "red with SAFE-RUN line" INCOMPLETE 3
case_end

case_begin "weak-pin-red-is-not-also-red" "experimental/test-jail/compare-runs.sh"
mk c11
jt_add "$W" 1 tests/a.sh state "PINNED: obtained=state requested=full fixture" "$FAILLINE"; jt_add "$B" 0 tests/a.sh full
jt_cmp "$W" "$B"
nc "red with weak pin" tests/a.sh WEAK-PIN
untouched "red with weak pin" tests/a.sh
verdict "red with weak pin" INCOMPLETE 3
case_end

case_begin "invalid-test-does-not-count-toward-valid-red" "experimental/test-jail/compare-runs.sh"
mk c12
jt_add "$W" 1 tests/a.sh full "" "$FAILLINE"$'\n'"$SAFE"; jt_add "$B" 0 tests/a.sh full
jt_add "$W" 1 tests/r.sh full "" "$FAILLINE"; jt_add "$B" 0 tests/r.sh full
jt_cmp "$W" "$B"
expect_eq "summary.tsv holds only the valid red" "$(cut -f1,7 "$JT_CMP/summary.tsv")" "BASE-GREEN${TAB}tests/r.sh"
nc "invalid test" tests/a.sh SAFE-RUN-LINE
untouched "invalid test" tests/a.sh
verdict "mixed" "NEW-RED (1 to read, 1 not compared)" 1
case_end

case_begin "unverifiable-pin-is-not-compared" "experimental/test-jail/compare-runs.sh"
mk c13a
jt_add "$W" 0 tests/a.sh unknown; jt_add "$B" 0 tests/a.sh full
jt_cmp "$W" "$B"
nc "unknown pin in changed" tests/a.sh UNVERIFIED-PIN
verdict "unknown pin in changed" INCOMPLETE 3
mk c13b
jt_add "$W" 0 tests/a.sh full; jt_add "$B" 0 tests/a.sh unknown
jt_cmp "$W" "$B"
nc "unknown pin in baseline" tests/a.sh UNVERIFIED-PIN
verdict "unknown pin in baseline" INCOMPLETE 3
case_end

case_begin "old-three-column-runs-are-never-trusted" "experimental/test-jail/compare-runs.sh"
mk c14a
jt_add "$W" 0 tests/a.sh -; jt_add "$B" 0 tests/a.sh -
jt_add "$W" 0 tests/b.sh -; jt_add "$B" 0 tests/b.sh -
jt_cmp "$W" "$B"
nc "3-column run" tests/a.sh UNVERIFIED-PIN
nc "3-column run" tests/b.sh UNVERIFIED-PIN
verdict "3-column run" INCOMPLETE 3
mk c14b
jt_add "$W" 1 tests/c.sh - "-" "$FAILLINE"; jt_add "$B" 1 tests/c.sh - "-" "$FAILLINE"
jt_cmp "$W" "$B"
nc "3-column red" tests/c.sh UNVERIFIED-PIN
untouched "3-column red" tests/c.sh
verdict "3-column red" INCOMPLETE 3
case_end

case_begin "green-changed-with-refused-baseline-is-not-compared" "experimental/test-jail/compare-runs.sh"
for brc in 95 96; do
  mk c15-$brc
  jt_add "$W" 0 tests/a.sh full; jt_add "$B" "$brc" tests/a.sh full
  jt_cmp "$W" "$B"
  nc "green changed, baseline rc $brc" tests/a.sh REFUSED
  untouched "green changed, baseline rc $brc" tests/a.sh
  verdict "green changed, baseline rc $brc" INCOMPLETE 3
done
case_end

case_begin "missing-log-is-not-compared" "experimental/test-jail/compare-runs.sh"
mk c16a
jt_add "$W" 0 tests/a.sh full; jt_add "$B" 0 tests/a.sh full
rm -f "$W/logs/tests__a.sh.log"
jt_cmp "$W" "$B"
expect_has "changed log missing: NO-LOG line" "$(cat "$JT_CMP/not-compared.tsv")" "NO-LOG${TAB}tests/a.sh"
verdict "changed log missing" INCOMPLETE 3
mk c16b
jt_add "$W" 0 tests/a.sh full; jt_add "$B" 0 tests/a.sh full
rm -f "$B/logs/tests__a.sh.log"
jt_cmp "$W" "$B"
expect_has "baseline log missing: NO-LOG line" "$(cat "$JT_CMP/not-compared.tsv")" "NO-LOG${TAB}tests/a.sh"
verdict "baseline log missing" INCOMPLETE 3
case_end

case_begin "red-with-missing-changed-log-is-not-new-red" "experimental/test-jail/compare-runs.sh"
mk c17
jt_add "$W" 1 tests/a.sh full; jt_add "$B" 0 tests/a.sh full
rm -f "$W/logs/tests__a.sh.log"
jt_cmp "$W" "$B"
expect_has "red, changed log missing: NO-LOG line" "$(cat "$JT_CMP/not-compared.tsv")" "NO-LOG${TAB}tests/a.sh"
expect_eq "red, changed log missing: no summary row" "$(jt_summary_rows tests/a.sh)" ""
verdict "red, changed log missing" INCOMPLETE 3
expect_lacks "red, changed log missing: not NEW-RED" "$JT_ALL" "VERDICT: NEW-RED"
case_end

case_begin "safe-run-line-outranks-missing-log" "experimental/test-jail/compare-runs.sh"
mk c18a
jt_add "$W" 0 tests/a.sh full; jt_add "$B" 0 tests/a.sh full "" "$SAFE"
rm -f "$W/logs/tests__a.sh.log"
jt_cmp "$W" "$B"
nc "changed log missing, SAFE-RUN in baseline" tests/a.sh SAFE-RUN-LINE
mk c18b
jt_add "$W" 0 tests/a.sh full "" "$SAFE"; jt_add "$B" 0 tests/a.sh full
rm -f "$B/logs/tests__a.sh.log"
jt_cmp "$W" "$B"
nc "baseline log missing, SAFE-RUN in changed" tests/a.sh SAFE-RUN-LINE
case_end

# Marker cases (compare side). CH/BA: two small all-green run dirs, unmarked, so a compare
# reaches NO-NEW-RED.
CH="$TMP_ROOT/changed"
BA="$TMP_ROOT/baseline"
jt_run_dir "$CH" && jt_add "$CH" 0 tests/a.sh full
jt_run_dir "$BA" && jt_add "$BA" 0 tests/a.sh full

case_begin "compare-refuses-an-unmarked-out-dir" "experimental/test-jail/jail-marker.sh"
D2="$TMP_ROOT/m2"
mkdir -p "$D2" && : >"$D2/summary.tsv" && printf 'keep\n' >"$D2/notes.txt"
jt_cmp_to "$D2" "$CH" "$BA"
expect_eq "unmarked non-empty compare dir: rc" "$JT_RC" "2"
expect_has "unmarked compare dir: ABORT line" "$JT_ALL" "ABORT:"
expect_eq "unmarked compare dir: summary.tsv is kept" "$(have_file "$D2/summary.tsv")" "yes"
expect_eq "unmarked compare dir: other content is kept" "$(have_file "$D2/notes.txt")" "yes"
case_end

case_begin "a-run-marker-protects-the-dir-from-compare" "experimental/test-jail/jail-marker.sh"
D3="$TMP_ROOT/m3"
jt_write_marker "$D3" run
: >"$D3/summary.tsv"
jt_cmp_to "$D3" "$CH" "$BA"
expect_eq "compare into a kind=run dir: rc" "$JT_RC" "2"
expect_eq "kind=run dir: summary.tsv is kept" "$(have_file "$D3/summary.tsv")" "yes"
expect_eq "kind=run dir: marker is kept" "$(have_file "$D3/.test-jail-dir")" "yes"
case_end

case_begin "own-compare-dir-is-replaced-on-rerun" "experimental/test-jail/jail-marker.sh"
D4="$TMP_ROOT/m4"
jt_cmp_to "$D4" "$CH" "$BA"
expect_eq "first compare: rc" "$JT_RC" "0"
printf 'stale\n' >"$D4/stray.txt"
jt_cmp_to "$D4" "$CH" "$BA"
expect_eq "second compare into the same dir: rc" "$JT_RC" "0"
expect_eq "second compare removed the earlier file" "$(have_file "$D4/stray.txt")" "no"
MK="$(cat "$D4/.test-jail-dir" 2>/dev/null)"
expect_has "marker: tool" "$MK" "tool=experimental/test-jail"
expect_has "marker: kind" "$MK" "kind=compare"
expect_has "marker: creator" "$MK" "creator=compare-runs.sh"
case_end

case_begin "empty-or-missing-compare-dir-is-accepted" "experimental/test-jail/jail-marker.sh"
D5="$TMP_ROOT/m5-empty"
mkdir -p "$D5"
jt_cmp_to "$D5" "$CH" "$BA"
expect_eq "empty existing dir: rc" "$JT_RC" "0"
expect_has "empty existing dir: the tool wrote the marker" "$(cat "$D5/.test-jail-dir" 2>/dev/null)" "kind=compare"
D5B="$TMP_ROOT/m5-missing"
jt_cmp_to "$D5B" "$CH" "$BA"
expect_eq "missing path: rc" "$JT_RC" "0"
expect_has "missing path: the tool wrote the marker" "$(cat "$D5B/.test-jail-dir" 2>/dev/null)" "kind=compare"
case_end

case_begin "compare-inputs-need-no-marker" "experimental/test-jail/jail-marker.sh"
expect_eq "premise: the changed run dir has no marker" "$(have_file "$CH/.test-jail-dir")" "no"
expect_eq "premise: the baseline run dir has no marker" "$(have_file "$BA/.test-jail-dir")" "no"
jt_cmp "$CH" "$BA"
expect_lacks "unmarked inputs are read, not refused" "$JT_ALL" "ABORT:"
expect_has "unmarked inputs reach a verdict" "$JT_ALL" "VERDICT: NO-NEW-RED"
expect_eq "unmarked inputs: rc" "$JT_RC" "0"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
