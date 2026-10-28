#!/usr/bin/env bash
# tests/hooks/feature-2631-precommit-size-gate.sh
# Tests: hooks/pre-commit, hooks/lib/precommit-size-gate.sh, bin/size-check
# Tags: scope:issue-specific, size-limits, pre-commit, hook, git, block, shrink, exempt, table-driven, layer:TL2, ssot, non-ascii-path, session-marker, fail-open, fail-closed, newline-path, mixed-kinds, initial-commit
# #2631 stage 3: hooks/pre-commit judges staged files through hooks/lib/precommit-size-gate.sh
# (one node call into bin/size-check): HARD verdicts, shrink-only, exempt records, SSOT propagation,
# odd names, session markers, fail-closed rc 2 / rc 3, the first commit (no HEAD), real `git commit`.
# The bin/size-check CLI contract is in -cli.sh.
set -uo pipefail
# TL3 gap (what this test does NOT catch):
# - the installer actually setting core.hooksPath on a developer host (git commit gets it with -c)
# - the other agents-repo gates, stubbed clean here, interacting with the size gate in a full checkout
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"
harness_assert_isolated
unset CLAUDE_CODE_SESSION_ID CODE_FILE_EXTENSIONS 2>/dev/null || true

# Bodies live in the sibling folder; lane.sh runs them, and every case below replays its lanes'
# sections. One hooks/pre-commit run costs about 7-10 s on a Windows host (twice that under load)
# and a lane's fixture about 10-15 s, so each lane holds at most 4-5 runs (about 30-50 s alone).
# Lanes run LANE_JOBS at a time: the host saturates, and 3 or 4 at once pushed 4-run lanes past
# LANE_TIMEOUT where 2 at once kept them near 70 s. A heavy table case is split across lanes by naming its rows
# (case=function:row:row); rebalance by moving a spec to another lane.
LANE_DIR="$ROOT/tests/hooks/feature-2631-precommit-size-gate"
LANE_TIMEOUT=110
LANE_JOBS=2

# lane | case=function[:row...] ... (heaviest first, so the last wave holds the short lanes)
LANE_TABLE="$(cat <<'EOF'
edge-session|session-markers-and-unresolved-sid=edge_case_session_markers_and_unresolved_sid
core-new-code-prompt|new-file-over-hard-blocks-exactly-hard-passes=core_case_new_file_over_hard_blocks_exactly_hard_passes:code:prompt
core-shrink|over-hard-head-file-may-shrink-only=core_case_over_hard_head_file_may_shrink_only
core-ssot|ssot-limit-change-propagates=core_case_ssot_limit_change_propagates
edge-nohead|initial-commit-over-hard-blocks-exactly-hard-passes=edge_case_initial_commit size-check-rc2-and-rc3-both-block-fail-closed=edge_case_size_check_rc2_and_rc3_block
names|odd-file-name-survives-the-nul-route=core_case_odd_file_name newline-path-is-checked-fail-closed=edge_case_newline_path
gc-mixed|git-commit-mixed-kinds-judges-every-staged-file=gc_case_mixed_kinds_small_then_over_hard
gc-route|git-commit-invokes-the-size-gate=gc_case_git_commit_invokes_the_gate git-commit-judges-the-staged-blob-not-the-worktree=gc_case_staged_size_beats_worktree_size
core-premise-new-docs|fixture-premise-small-commit-passes=core_case_fixture_premise gate-makes-exactly-one-node-call=core_case_gate_makes_exactly_one_node_call non-agents-repo-is-a-no-op=edge_case_non_agents_repo_is_a_no_op new-file-over-hard-blocks-exactly-hard-passes=core_case_new_file_over_hard_blocks_exactly_hard_passes:docs
core-exempt-a|exempt-stream-records-pass=core_case_exempt_stream_records_pass:docs/history.md:CHANGELOG.md:docs/history/2026.md
gc-shrink-exempt-b|git-commit-allows-an-index-shrink-of-an-over-hard-file=gc_case_shrink_of_over_hard_file_judged_by_index exempt-stream-records-pass=core_case_exempt_stream_records_pass:changelog/2026.md:docs/_archive/old.md
gc-meta|shell-metacharacter-path-survives-the-nul-route=gc_case_shell_metachar_path
merge|merge-incoming-equal-passes-differing-blocks=merge_case_incoming_equal_passes_differing_blocks
EOF
)"
readonly LANE_TABLE
running=0
while IFS='|' read -r lane specs; do
  [[ -z "$lane" || "$lane" =~ ^[[:space:]]*# ]] && continue
  if ((running >= LANE_JOBS)); then wait -n; running=$((running - 1)); fi
  # shellcheck disable=SC2086 # specs is a word list on purpose
  run_with_timeout "$LANE_TIMEOUT" bash "$LANE_DIR/lane.sh" "$TMP_ROOT/$lane" $specs < /dev/null > "$TMP_ROOT/lane-$lane.log" 2>&1 &
  running=$((running + 1))
done <<<"$LANE_TABLE"
wait

# lane_gaps <log-dir> <case-name> [table] — one line per missing result: a lane the table names for
# the case whose log is absent, holds fewer closed sections of the case than the table has rows for
# it, or never printed @@DONE. replay fails on each line, so the other lanes cannot hide a dead one.
lane_gaps() {
  local dir="$1" name="$2" table="${3:-$LANE_TABLE}" lane specs spec want got finished log line state
  while IFS='|' read -r lane specs; do
    [[ -z "$lane" || "$lane" =~ ^[[:space:]]*# ]] && continue
    want=0
    for spec in $specs; do [[ "${spec%%=*}" == "$name" ]] && want=$((want + 1)); done
    ((want == 0)) && continue
    log="$dir/lane-$lane.log"
    if [[ ! -f "$log" ]]; then printf 'lane %s: no log\n' "$lane"; continue; fi
    got=0 finished=0 state=out
    while IFS= read -r line; do
      [[ "$line" == @@* ]] || continue
      [[ "$state" == in ]] && got=$((got + 1))
      [[ "$line" == "@@DONE" ]] && finished=1
      if [[ "$line" == "@@CASE $name" ]]; then state=in; else state=out; fi
    done < "$log"
    ((got >= want)) || printf 'lane %s: %d of %d sections of %s closed\n' "$lane" "$got" "$want" "$name"
    ((finished == 1)) || printf 'lane %s: no @@DONE (the lane did not finish)\n' "$lane"
  done <<<"$table"
}

# replay <case-name> — re-issue every lane section of the case (a split case has several) in this
# file's open case; no section, a section with no closing @@ line (lane crashed or timed out), or a
# section with no assertion fails. Each log is read on its own, so a killed lane's open section
# cannot close on the next log's @@CASE line.
replay() {
  local name="$1" line state log seen=0 asserted gap
  while IFS= read -r gap; do
    [[ -n "$gap" ]] && fail "every lane named for case $name finished it" "$gap"
  done <<<"$(lane_gaps "$TMP_ROOT" "$name")"
  for log in "$TMP_ROOT"/lane-*.log; do
    state=out
    while IFS= read -r line; do
      if [ "$state" = in ]; then
        case "$line" in
          @@*) state=closed
            break ;;
          "PASS: "*) pass "${line#PASS: }"; asserted=1 ;;
          "FAIL: "*) fail "${line#FAIL: }"; asserted=1 ;;
          "SKIP: "*) skip "${line#SKIP: }"; asserted=1 ;;
          *) printf '%s\n' "$line" ;;
        esac
      elif [ "$line" = "@@CASE $name" ]; then
        state=in asserted=0 seen=$((seen + 1))
      fi
    done < "$log"
    if [ "$state" = in ]; then fail "lane finished case $name" "no closing marker in ${log##*/}; the lane crashed or passed ${LANE_TIMEOUT}s"
    elif [ "$state" = closed ] && [ "$asserted" = 0 ]; then fail "lane section of case $name asserts something" "empty section in ${log##*/} (a row filter matched nothing?)"; fi
  done
  if [ "$seen" = 0 ]; then fail "lane reached case $name" "no section; a lane died before it (log tails: $(tail -n 3 "$TMP_ROOT"/lane-*.log | head -c 600))"; fi
}

case_begin "replay-fails-when-one-lane-result-is-missing" "hooks/pre-commit"
SC_DIR="$TMP_ROOT/replay-selfcheck"
mkdir -p "$SC_DIR"
SC_TABLE=$'ok|split=f:a\ngone|split=f:b\ncut|split=f:c\nfull|whole=f'
printf '@@CASE split\nPASS: a\n@@DONE\n' > "$SC_DIR/lane-ok.log"
printf '@@CASE split\nPASS: c\n' > "$SC_DIR/lane-cut.log"
printf '@@CASE whole\nPASS: w\n@@DONE\n' > "$SC_DIR/lane-full.log"
sc_gaps="$(lane_gaps "$SC_DIR" split "$SC_TABLE")"
for sc_want in "lane gone: no log" "lane cut: 0 of 1 sections of split closed" "lane cut: no @@DONE"; do
  if [[ "$sc_gaps" == *"$sc_want"* ]]; then pass "gap reported: $sc_want"
  else fail "gap reported: $sc_want" "got: $sc_gaps"; fi
done
if [[ "$sc_gaps" != *"lane ok"* ]]; then pass "a finished lane reports no gap"
else fail "a finished lane reports no gap" "got: $sc_gaps"; fi
assert_eq "$(lane_gaps "$SC_DIR" whole "$SC_TABLE")" ""
case_end

case_begin "fixture-premise-small-commit-passes" "hooks/pre-commit"
replay fixture-premise-small-commit-passes
case_end

case_begin "new-file-over-hard-blocks-exactly-hard-passes" "hooks/lib/precommit-size-gate.sh"
replay new-file-over-hard-blocks-exactly-hard-passes
case_end

case_begin "gate-makes-exactly-one-node-call" "hooks/lib/precommit-size-gate.sh"
replay gate-makes-exactly-one-node-call
case_end

case_begin "over-hard-head-file-may-shrink-only" "hooks/lib/precommit-size-gate.sh"
replay over-hard-head-file-may-shrink-only
case_end

case_begin "exempt-stream-records-pass" "hooks/lib/precommit-size-gate.sh"
replay exempt-stream-records-pass
case_end

case_begin "odd-file-name-survives-the-nul-route" "bin/size-check"
replay odd-file-name-survives-the-nul-route
case_end

case_begin "ssot-limit-change-propagates" "hooks/lib/precommit-size-gate.sh"
replay ssot-limit-change-propagates
case_end

case_begin "initial-commit-over-hard-blocks-exactly-hard-passes" "bin/size-check"
replay initial-commit-over-hard-blocks-exactly-hard-passes
case_end

case_begin "session-markers-and-unresolved-sid" "hooks/lib/precommit-size-gate.sh"
replay session-markers-and-unresolved-sid
case_end

case_begin "non-agents-repo-is-a-no-op" "hooks/pre-commit"
replay non-agents-repo-is-a-no-op
case_end

case_begin "size-check-rc2-and-rc3-both-block-fail-closed" "bin/size-check"
replay size-check-rc2-and-rc3-both-block-fail-closed
case_end

case_begin "newline-path-is-checked-fail-closed" "bin/size-check"
replay newline-path-is-checked-fail-closed
case_end

case_begin "git-commit-invokes-the-size-gate" "hooks/pre-commit"
replay git-commit-invokes-the-size-gate
case_end

case_begin "git-commit-judges-the-staged-blob-not-the-worktree" "hooks/pre-commit"
replay git-commit-judges-the-staged-blob-not-the-worktree
case_end

case_begin "git-commit-allows-an-index-shrink-of-an-over-hard-file" "hooks/pre-commit"
replay git-commit-allows-an-index-shrink-of-an-over-hard-file
case_end

case_begin "git-commit-mixed-kinds-judges-every-staged-file" "hooks/pre-commit"
replay git-commit-mixed-kinds-judges-every-staged-file
case_end

case_begin "shell-metacharacter-path-survives-the-nul-route" "hooks/lib/precommit-size-gate.sh"
replay shell-metacharacter-path-survives-the-nul-route
case_end

case_begin "merge-incoming-equal-passes-differing-blocks" "hooks/pre-commit"
replay merge-incoming-equal-passes-differing-blocks
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
