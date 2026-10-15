#!/usr/bin/env bash
# Tests: experimental/test-jail/jail-marker.sh, experimental/test-jail/run-list.sh
# Tags: scope:issue-specific, tl2, test-jail, fixture-isolation
#
# #2591: run-list.sh deletes an existing output dir only when it carries the .test-jail-dir marker
# of kind=run that jail-marker.sh wrote when it made the dir. A non-empty dir without it, or with
# a marker of another kind, is left alone and the run aborts with rc 2. The tool offers no way to
# add a marker to an existing dir. (The compare-runs.sh side: feature-2591-test-jail-compare.sh.)

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
T_NONE="$TMP_ROOT/tree-none"
jt_make_tree "$T_NONE" none-fn || { echo "FAIL: fixture tree"; exit 1; }
LIST="$TMP_ROOT/list.txt"
printf '%s\n' tests/ok.sh >"$LIST"
LANE_SKIP="no host test lane could be acquired (rc 4); lanes are a host-wide resource"

# without_dir <out-text> <dir> — the output with the dir's own path removed, so a random
# temp name cannot match a word the guidance must not contain.
without_dir() { printf '%s' "${1//$2/}"; }

# dir_snapshot <dir> — every entry's relative path, sorted, plus each regular file's checksum.
dir_snapshot() {
  local p
  (cd "$1" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r p; do
    if [[ -f "$p" ]]; then printf '%s %s\n' "$p" "$(cksum <"$p")"; else printf '%s\n' "$p"; fi
  done)
}

# precheck_foreign <name> <marker-text> — a non-empty run dir whose marker is not this tool's.
precheck_foreign() {
  local d="$TMP_ROOT/m7-$1" before
  mkdir -p "$d/sub" && printf 'keep\n' >"$d/notes.txt" && printf 'deep\n' >"$d/sub/.hidden"
  printf '%b' "$2" >"$d/.test-jail-dir"
  before="$(dir_snapshot "$d")"
  jt_marker_fn jail_marker_precheck "$d" run
  expect_eq "$1: precheck rc" "$JT_RC" "2"
  expect_eq "$1: dir is unchanged" "$(dir_snapshot "$d")" "$before"
}

case_begin "run-list-refuses-an-unmarked-run-dir" "experimental/test-jail/run-list.sh"
D1="$TMP_ROOT/m1"
mkdir -p "$D1/logs" && printf '0\t3\ttests/ok.sh\n' >"$D1/results.tsv" && printf 'keep\n' >"$D1/notes.txt" && printf 'log\n' >"$D1/logs/a.log"
SNAP1="$(dir_snapshot "$D1")"
jt_run_list "$LIST" "$D1" "$T_NONE" none
expect_eq "unmarked non-empty run dir: rc" "$JT_RC" "2"
expect_has "unmarked: ABORT line" "$JT_ALL" "ABORT:"
G="$(without_dir "$JT_ALL" "$D1")"
expect_has "guidance: choose another path" "$G" "Choose a new output path"
expect_has "guidance: delete it yourself" "$G" "delete the directory yourself"
expect_lacks "guidance does not name jail-marker.sh" "$G" "jail-marker.sh"
expect_lacks "guidance does not suggest writing a marker" "$G" "write"
expect_eq "unmarked: dir is unchanged" "$(dir_snapshot "$D1")" "$SNAP1"
expect_lacks "unmarked: no lane was taken" "$JT_ALL" "lanes:"
case_end

case_begin "a-compare-marker-protects-the-dir-from-run-list" "experimental/test-jail/run-list.sh"
D2="$TMP_ROOT/m2"
jt_write_marker "$D2" compare
printf '0\t3\ttests/ok.sh\n' >"$D2/results.tsv"
SNAP2="$(dir_snapshot "$D2")"
jt_run_list "$LIST" "$D2" "$T_NONE" none
expect_eq "run-list into a kind=compare dir: rc" "$JT_RC" "2"
expect_has "kind=compare dir: ABORT line" "$JT_ALL" "ABORT:"
expect_eq "kind=compare dir: dir is unchanged" "$(dir_snapshot "$D2")" "$SNAP2"
expect_lacks "kind=compare dir: no lane was taken" "$JT_ALL" "lanes:"
case_end

case_begin "own-run-dir-is-replaced-on-rerun" "experimental/test-jail/run-list.sh"
D3="$TMP_ROOT/m3"
jt_run_list "$LIST" "$D3" "$T_NONE" none
if [[ "$JT_RC" -eq 4 ]]; then
  skip "run-list rerun: $LANE_SKIP"
else
  expect_eq "first run-list: rc" "$JT_RC" "0"
  printf 'stale\n' >"$D3/stray.txt"
  jt_run_list "$LIST" "$D3" "$T_NONE" none
  if [[ "$JT_RC" -eq 4 ]]; then
    skip "run-list rerun, second run: $LANE_SKIP"
  else
    expect_eq "second run-list into the same dir: rc" "$JT_RC" "0"
    expect_eq "second run removed the earlier file" "$(have_file "$D3/stray.txt")" "no"
    MK="$(cat "$D3/.test-jail-dir" 2>/dev/null)"
    expect_has "marker: tool" "$MK" "tool=experimental/test-jail"
    expect_has "marker: kind" "$MK" "kind=run"
    expect_has "marker: creator" "$MK" "creator=run-list.sh"
  fi
fi
case_end

case_begin "empty-or-missing-run-dir-is-accepted" "experimental/test-jail/run-list.sh"
D4="$TMP_ROOT/m4-empty"
mkdir -p "$D4"
jt_run_list "$LIST" "$D4" "$T_NONE" none
if [[ "$JT_RC" -eq 4 ]]; then
  skip "run-list into an empty dir: $LANE_SKIP"
else
  expect_eq "empty existing dir: rc" "$JT_RC" "0"
  expect_has "empty existing dir: the tool wrote the marker" "$(cat "$D4/.test-jail-dir" 2>/dev/null)" "kind=run"
fi
D4B="$TMP_ROOT/m4-missing"
jt_run_list "$LIST" "$D4B" "$T_NONE" none
if [[ "$JT_RC" -eq 4 ]]; then
  skip "run-list into a missing path: $LANE_SKIP"
else
  expect_eq "missing path: rc" "$JT_RC" "0"
  expect_has "missing path: the tool wrote the marker" "$(cat "$D4B/.test-jail-dir" 2>/dev/null)" "kind=run"
fi
case_end

case_begin "precheck-refuses-dangerous-dirs-even-with-a-marker" "experimental/test-jail/jail-marker.sh"
jt_marker_fn jail_marker_precheck "" run
expect_eq "precheck of an empty string: rc" "$JT_RC" "2"
jt_marker_fn jail_marker_precheck / run
expect_eq "precheck of /: rc" "$JT_RC" "2"
D5="$TMP_ROOT/m5-git"
jt_write_marker "$D5" run
mkdir -p "$D5/.git" && printf 'ref: x\n' >"$D5/.git/HEAD"
SNAP5="$(dir_snapshot "$D5")"
jt_marker_fn jail_marker_precheck "$D5" run
expect_eq "precheck of a dir holding .git, marker present: rc" "$JT_RC" "2"
expect_eq "dir holding .git: dir is unchanged" "$(dir_snapshot "$D5")" "$SNAP5"
D5H="$TMP_ROOT/m5-home"
jt_write_marker "$D5H" run
printf 'mine\n' >"$D5H/profile.txt"
SNAP5H="$(dir_snapshot "$D5H")"
JT_ENVV=(HOME="$D5H")
jt_marker_fn jail_marker_precheck "$D5H" run
expect_eq "precheck of HOME, marker present: rc" "$JT_RC" "2"
expect_eq "HOME: dir is unchanged" "$(dir_snapshot "$D5H")" "$SNAP5H"
D5OK="$TMP_ROOT/m5-ok"
jt_write_marker "$D5OK" run
jt_marker_fn jail_marker_precheck "$D5OK" run
expect_eq "precheck of an ordinary marked dir of the right kind: rc" "$JT_RC" "0"
case_end

case_begin "a-marker-of-another-tool-is-refused" "experimental/test-jail/jail-marker.sh"
FOREIGN_MARKERS=(
  'other-tool|tool=some/other-tool\nkind=run\n'
  'tool-as-suffix-of-a-line|xtool=experimental/test-jail\nkind=run\n'
  'tool-as-prefix-of-a-line|tool=experimental/test-jail-other\nkind=run\n'
  'no-kind-line|tool=experimental/test-jail\ncreator=fixture\n'
  'empty-marker|'
)
for row in "${FOREIGN_MARKERS[@]}"; do precheck_foreign "${row%%|*}" "${row#*|}"; done
case_end

case_begin "no-way-to-add-a-marker-to-an-existing-dir" "experimental/test-jail/jail-marker.sh"
D6="$TMP_ROOT/m6"
mkdir -p "$D6" && printf '0\t3\ttests/ok.sh\n' >"$D6/results.tsv"
SNAP6="$(dir_snapshot "$D6")"
jt_exec jail-marker.sh write "$D6" run
expect_eq "running jail-marker.sh directly: rc" "$JT_RC" "2"
expect_has "direct run: says it is for sourcing" "${JT_ERR,,}" "source"
jt_run_list "$LIST" "$D6" "$T_NONE" none
expect_eq "run-list into that dir afterwards: rc" "$JT_RC" "2"
expect_eq "neither run touched the dir (no marker added)" "$(dir_snapshot "$D6")" "$SNAP6"
jt_marker_fn declare -F
PUBLIC="$(printf '%s\n' "$JT_OUT" | awk '$3 ~ /^jail_marker/{printf "%s ", $3}')"
expect_eq "public functions" "$PUBLIC" "jail_marker_check jail_marker_precheck jail_marker_prepare "
expect_lacks "no public marker-writing function" "$JT_OUT" " jail_marker_write"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
