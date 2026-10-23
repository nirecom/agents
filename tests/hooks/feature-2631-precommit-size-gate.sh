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

# Bodies live in the sibling folder; lane.sh runs them. Serially they cost over 200 s, so the
# lanes below (each about 30-40 s alone) start together and every case below replays its lane's
# section. Rebalance by moving a case=function pair to another lane.
LANE_DIR="$ROOT/tests/hooks/feature-2631-precommit-size-gate"
LANE_TIMEOUT=110

# lane | case=function ...
while IFS='|' read -r lane specs; do
  [[ -z "$lane" || "$lane" =~ ^[[:space:]]*# ]] && continue
  # shellcheck disable=SC2086 # specs is a word list on purpose
  run_with_timeout "$LANE_TIMEOUT" bash "$LANE_DIR/lane.sh" "$TMP_ROOT/$lane" $specs < /dev/null > "$TMP_ROOT/lane-$lane.log" 2>&1 &
done <<'EOF'
core-new|fixture-premise-small-commit-passes=core_case_fixture_premise new-file-over-hard-blocks-exactly-hard-passes=core_case_new_file_over_hard_blocks_exactly_hard_passes gate-makes-exactly-one-node-call=core_case_gate_makes_exactly_one_node_call
core-head|over-hard-head-file-may-shrink-only=core_case_over_hard_head_file_may_shrink_only exempt-stream-records-pass=core_case_exempt_stream_records_pass
core-ssot|odd-file-name-survives-the-nul-route=core_case_odd_file_name ssot-limit-change-propagates=core_case_ssot_limit_change_propagates initial-commit-over-hard-blocks-exactly-hard-passes=edge_case_initial_commit
edges|session-markers-and-unresolved-sid=edge_case_session_markers_and_unresolved_sid non-agents-repo-is-a-no-op=edge_case_non_agents_repo_is_a_no_op size-check-rc2-and-rc3-both-block-fail-closed=edge_case_size_check_rc2_and_rc3_block newline-path-is-checked-fail-closed=edge_case_newline_path
gc-route|git-commit-invokes-the-size-gate=gc_case_git_commit_invokes_the_gate git-commit-judges-the-staged-blob-not-the-worktree=gc_case_staged_size_beats_worktree_size
gc-shrink|git-commit-allows-an-index-shrink-of-an-over-hard-file=gc_case_shrink_of_over_hard_file_judged_by_index shell-metacharacter-path-survives-the-nul-route=gc_case_shell_metachar_path
gc-mixed|git-commit-mixed-kinds-judges-every-staged-file=gc_case_mixed_kinds_small_then_over_hard
EOF
wait

# replay <case-name> — re-issue the lane section's PASS / FAIL / SKIP lines in this file's open
# case; a missing section or one with no closing @@ line (lane crashed or timed out) fails.
replay() {
  local name="$1" line state=out closed=0
  while IFS= read -r line; do
    if [ "$state" = in ]; then
      case "$line" in
        @@*) closed=1
          break ;;
        "PASS: "*) pass "${line#PASS: }" ;;
        "FAIL: "*) fail "${line#FAIL: }" ;;
        "SKIP: "*) skip "${line#SKIP: }" ;;
        *) printf '%s\n' "$line" ;;
      esac
    elif [ "$line" = "@@CASE $name" ]; then
      state=in
    fi
  done < <(cat "$TMP_ROOT"/lane-*.log)
  if [ "$state" = out ]; then fail "lane reached case $name" "no section; a lane died before it (log tails: $(tail -n 3 "$TMP_ROOT"/lane-*.log | head -c 600))"
  elif [ "$closed" = 0 ]; then fail "lane finished case $name" "no closing marker; the lane crashed or passed ${LANE_TIMEOUT}s"; fi
}

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

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
