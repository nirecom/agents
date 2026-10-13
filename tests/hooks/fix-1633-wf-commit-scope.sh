#!/usr/bin/env bash
# fix-1633-wf-commit-scope.sh
# Tests: hooks/workflow-gate.js, hooks/workflow-gate/commit-scope.js
# Tags: workflow, gate, hook, git, cross-repo, scope:issue-specific, TL2
# fix-1633 (TL2): a commit is checked only once the session's WF has begun AND its
# target is in the WF target repo set (session-start repo plus intent worktrees).
# The gate runs straight from this checkout (no attach).

# TL3 gap: only a real session proves clarify-intent writes the worktree paths read
# here and that runCommands / multi-line Bash payloads reach the gate in this shape.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT"
unset CLAUDE_CODE_SESSION_ID

# Case bodies (tc_*) live in the sibling folder; this entry owns the case boundaries.
FRAGMENT_DIR="$(dirname "$0")/fix-1633-wf-commit-scope"
# shellcheck source=tests/hooks/fix-1633-wf-commit-scope/common.sh
. "$FRAGMENT_DIR/common.sh"
for frag in cases-1-4 begun target-set shapes repo-dir wip multi-target; do
  # shellcheck source=/dev/null
  . "$FRAGMENT_DIR/$frag.sh"
done

echo "=== fix-1633: WF commit scope ==="

# --- static: the old bypass design is gone ---
case_begin "static-old-bypass-symbols-removed" "hooks/workflow-gate.js"
for sym in isAgentsSessionRepo commitsAllOutsideWorkTargetRepo selectGateRepoDir; do
  if grep -rq "$sym" "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate.js" "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate"; then
    fail "(static) $sym absent from the gate" "still referenced under hooks/workflow-gate*"
  else
    pass "(static) $sym absent from the gate"
  fi
done
case_end

case_begin "static-work-target-repo-module-removed" "hooks/workflow-gate/work-target-repo.js"
if [ -e "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate/work-target-repo.js" ]; then
  fail "(static) hooks/workflow-gate/work-target-repo.js is removed" "file still exists"
else
  pass "(static) hooks/workflow-gate/work-target-repo.js is removed"
fi
if [ -f "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate/commit-scope.js" ]; then
  pass "(static) hooks/workflow-gate/commit-scope.js exists"
else
  fail "(static) hooks/workflow-gate/commit-scope.js exists" "file missing"
fi
case_end

case_begin "static-gate-within-hard-limit" "hooks/workflow-gate.js"
gate_lines="$(wc -l <"$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate.js")"
if [ "$gate_lines" -le 500 ]; then
  pass "(static) workflow-gate.js <= 500 lines ($gate_lines)"
else
  fail "(static) workflow-gate.js <= 500 lines" "$gate_lines lines"
fi
case_end

# --- Case 1-4 ---
case_begin "case1-no-state-approves" "hooks/workflow-gate/commit-scope.js"
tc_case1_no_state
case_end
case_begin "case1-init-pending-approves" "hooks/workflow-gate/commit-scope.js"
tc_case1_init_pending
case_end
case_begin "case2-cwd-a-checks-a-only" "hooks/workflow-gate/commit-scope.js"
tc_case2
case_end
case_begin "case3-cwd-b-checks-b-only" "hooks/workflow-gate/commit-scope.js"
tc_case3
case_end
case_begin "case4-intent-worktree-joins-set" "hooks/workflow-gate/commit-scope.js"
tc_case4
case_end

# --- begun ---
case_begin "begun-corrupt-state-blocks-unreadable" "hooks/workflow-gate/commit-scope.js"
tc_begun_corrupt
case_end
case_begin "begun-traversal-sid-blocks" "hooks/workflow-gate/commit-scope.js"
tc_begun_traversal
case_end
case_begin "begun-init-in-progress-checked" "hooks/workflow-gate/commit-scope.js"
tc_begun_init_in_progress
case_end
case_begin "begun-no-cwd-set-unknown-checked" "hooks/workflow-gate/commit-scope.js"
tc_begun_no_cwd
case_end
case_begin "begun-reset-to-init-approves" "hooks/workflow-gate.js"
tc_begun_reset_to_init
case_end

# --- target-set: unresolved intent sibling ---
case_begin "target-set-other-repo-possibly-in" "hooks/workflow-gate/commit-scope.js"
tc_ts_other_repo_checked
case_end
case_begin "target-set-main-checked" "hooks/workflow-gate/commit-scope.js"
tc_ts_main_checked
case_end
case_begin "target-set-two-repos-split" "hooks/workflow-gate/commit-scope.js"
tc_ts_main_and_other_split
case_end
case_begin "target-set-ambiguous-blocks" "hooks/workflow-gate/commit-scope.js"
tc_ts_ambiguous_two_members
case_end

# --- shapes ---
case_begin "shapes-begun-checked" "hooks/workflow-gate/commit-scope.js"
tc_shapes_begun_checked
case_end
case_begin "shapes-not-begun-approves" "hooks/workflow-gate/commit-scope.js"
tc_shapes_not_begun_approves
case_end
case_begin "shapes-later-runcommands-element" "hooks/workflow-gate.js"
tc_shapes_later_element
case_end
case_begin "shapes-later-logical-line" "hooks/workflow-gate.js"
tc_shapes_later_line
case_end
case_begin "shapes-value-flag-skipped" "hooks/lib/commit-targets.js"
tc_shapes_value_flag_skipped
case_end

# --- repo-dir: default commit target ---
case_begin "repo-dir-outside-linked-worktree-approves" "hooks/workflow-gate/commit-scope.js"
tc_rd_outside_linked_worktree
case_end
case_begin "repo-dir-outside-main-checkout-checked" "hooks/workflow-gate/commit-scope.js"
tc_rd_outside_main_checkout
case_end
case_begin "repo-dir-nondeterministic-source-checked" "hooks/workflow-gate/commit-scope.js"
tc_rd_nondeterministic_source
case_end
case_begin "repo-dir-project-dir-mismatch-checked" "hooks/workflow-gate/commit-scope.js"
tc_rd_project_dir_mismatch
case_end

# --- wip ---
case_begin "wip-later-runcommands-element-approves" "hooks/workflow-gate.js"
tc_wip_later_element
case_end
case_begin "wip-later-logical-line-approves" "hooks/workflow-gate.js"
tc_wip_later_line
case_end
case_begin "wip-mixed-blocks" "hooks/workflow-gate.js"
tc_wip_mixed
case_end
case_begin "wip-single" "hooks/workflow-gate.js"
tc_wip_single
case_end

# --- multi-target ---
case_begin "multi-two-repos-split-blocks" "hooks/workflow-gate/commit-scope.js"
tc_mt_two_repos_split
case_end
case_begin "multi-main-and-linked-one-repo" "hooks/workflow-gate/commit-scope.js"
tc_mt_main_and_linked_one_repo
case_end
case_begin "multi-in-and-out-checks-in-repo" "hooks/workflow-gate/commit-scope.js"
tc_mt_in_and_out_checks_in
case_end
case_begin "multi-ambiguous-two-members-blocks" "hooks/workflow-gate/commit-scope.js"
tc_mt_ambiguous_with_two_members
case_end
case_begin "multi-ambiguous-one-member-checked" "hooks/workflow-gate/commit-scope.js"
tc_mt_ambiguous_with_one_member
case_end
case_begin "multi-ambiguous-only-check-target" "hooks/workflow-gate/commit-scope.js"
tc_mt_ambiguous_only_target
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
