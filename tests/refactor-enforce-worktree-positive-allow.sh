#!/bin/bash
# tests/refactor-enforce-worktree-positive-allow.sh
# Tests: bin/compose-doc-append-entry, bin/lib/, bin/lib/github-contents-validate.sh, bin/lib/github-contents-write.sh, bin/lib/github-git-data-write.sh, hooks/enforce-worktree.js, skills/issue-close-finalize/scripts/step-e.sh, skills/issue-create/SKILL.md
# Tags: worktree, enforce, hook, issue-close, finalize
#
# Tests for refactor/enforce-worktree-positive-allow.
#
# The refactor:
#   1. Removes 4 bypass functions from hooks/enforce-worktree.js:
#      - isAllowedHistoryWriteViaIssueCloseSkill
#      - isAllowedHistoryPushViaIssueCloseSkill
#      - isAllowedHistoryWriteViaComposeDocAppendSkill
#      - isAllowedHistoryPushViaComposeDocAppendSkill
#   2. Replaces ISSUE_CLOSE_SKILL=1 / COMPOSE_DOC_APPEND_SKILL=1 bypass paths
#      with positive-allow: writes from main worktree go through GitHub Contents
#      API + Git Data API helpers, not local git commands.
#   3. Introduces three new helpers under bin/lib/:
#      - github-contents-validate.sh
#      - github-contents-write.sh
#      - github-git-data-write.sh
#   4. Tightens enforce-worktree.js: when Bash CWD is non-git and the command
#      is write-classified, BLOCK instead of fail-open. (Edit/Write to a
#      non-git path remains fail-open.)
#
# The tests deliberately fail meaningfully against the current source. They
# express the post-refactor contract.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_DIR="$SCRIPT_DIR/refactor-enforce-worktree-positive-allow"
# shellcheck source=/dev/null
. "$SUB_DIR/setup.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/l1-bypass.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/l1-validate.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/l1-write.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/l1-git-data.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/l1-730.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/l2-hook.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/l3-subsumes.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/l3-713.sh"

# ============ Run all ============

# L1 — enforce-worktree.js
test_l1_1_bypass_functions_not_exported
test_l1_2_issue_close_skill_inline_blocked_in_main
test_l1_3_compose_doc_append_skill_inline_blocked_in_main
test_l1_3b_compose_doc_append_no_prefix_via_bash_allowed_from_main
test_l1_4_bash_in_non_git_cwd_blocks
test_l1_5_edit_to_non_git_path_allows
test_l1_6_linked_worktree_feature_branch_allows
test_l1_7_main_worktree_denies
test_l1_8_existing_lifecycle_exceptions_intact

# L1 — github-contents-validate.sh
test_l1_9_validate_accepts_well_formed_history
test_l1_10_validate_rejects_empty_file
test_l1_11_validate_rejects_over_hard_limit
test_l1_12_validate_rejects_wrong_commit_subject
test_l1_13_validate_rejects_no_trailing_newline
test_l1_14_validate_warns_on_non_ascii_english

# L1 — github-contents-write.sh
test_l1_15_contents_write_success
test_l1_16_contents_write_409_retries
test_l1_17_contents_write_422_exhausted
test_l1_18_contents_write_base64_no_newlines

# L1 — github-git-data-write.sh
test_l1_19_git_data_call_order_single_file
test_l1_20_git_data_blobs_before_tree
test_l1_21_git_data_tree_entry_payload
test_l1_22_git_data_ref_patch_422_exhausted
test_l1_23_git_data_ref_patch_422_then_success

# L1 — #730 large-file --input regression
test_l1_46_git_data_blob_uses_input_json
test_l1_47_git_data_no_inline_content_in_invocations
test_l1_48_contents_write_uses_input_json

# L2 — integration
test_l2_24_main_issue_close_skill_add_history_blocked
test_l2_25_linked_worktree_normal_bash_write_allowed
test_l2_26_main_gh_api_put_contents_allowed
test_l2_27_non_git_cwd_bash_blocked
test_l2_28_non_git_path_write_tool_allowed
test_l2_29_linked_worktree_gh_api_post_blob_allowed
test_l2_30_main_git_push_origin_main_blocked

# L3 — E2E / subsumes
test_l3_31_issue_672_step_e_no_local_git_writes
test_l3_32_issue_713_issue_create_skill_no_main_worktree_abort
test_l3_33_issue_527_gh_api_patch_refs_from_linked_worktree
test_l3_34_issue_419_write_tool_to_workflow_plans
test_l3_35_issue_359_stderr_devnull_in_command_subst
test_l3_36_issue_713_skill_inline_prefix_allowed_from_main
test_l3_37_issue_713_msys_plus_skill_prefix_allowed_from_main
test_l3_38_issue_713_bare_gh_issue_create_blocked_from_main
test_l3_39_issue_713_bare_gh_issue_create_allowed_from_linked
test_l3_40_issue_713_skill_prefix_also_allowed_from_linked
test_l3_41_issue_659_multiline_body_sanctioned_not_blocked_from_main
test_l3_42_issue_659_multiline_body_bare_blocked_for_skill_reason_from_main
test_l3_43_issue_713_process_env_alone_does_not_authorize
test_l3_44_issue_713_other_gh_kinds_unaffected_main_in_session
test_l3_45_issue_713_other_gh_kinds_unaffected_linked

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
