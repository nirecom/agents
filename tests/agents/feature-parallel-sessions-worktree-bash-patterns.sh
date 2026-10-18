#!/bin/bash
# tests/agents/feature-parallel-sessions-worktree-bash-patterns.sh
# Tests: bin/github-issues/issue-create-dispatch.sh, hooks/lib/bash-write-patterns.js, hooks/pre-commit
# Tags: git, pre-commit, hook, issue-create, github, scope:issue-specific
# Dispatch-only: sources helper + thematic parts from tests/agents/feature-parallel-sessions-worktree-bash-patterns/
# and runs each test function.
# L3 gap: parts exercise the bash write/read classifier and pre-commit helpers as L2 units (real node,
# fixtures, no live session). Not driven end-to-end: the full pre-commit hook or the enforce-worktree
# PreToolUse pipeline; only a real host confirms event registration, settings loading and shell tokenization.

set -u

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PARTS_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-parallel-sessions-worktree-bash-patterns"

# shellcheck disable=SC1091
source "$PARTS_DIR/_common.sh"
# shellcheck disable=SC1091
source "$PARTS_DIR/basics.sh"
# shellcheck disable=SC1091
source "$PARTS_DIR/edge-and-git.sh"
# shellcheck disable=SC1091
source "$PARTS_DIR/gh-group-a.sh"
# shellcheck disable=SC1091
source "$PARTS_DIR/dq-and-strip.sh"

# ============ Run all ============
test_write_cases
test_heredoc_token_classified_write
test_read_cases
test_classify_null
test_classify_undefined
test_classify_number
test_classify_empty
test_compound_command
test_quoted_false_positive_documented
test_unicode_command
test_very_long_command
test_multiline_command
test_idempotency
test_security_compound_destructive
test_security_encoded_bypass
test_documented_python_false_negative
test_write_patterns_export
test_heredoc_quoted_tokens
test_fd_redirect_documented_fp
test_newline_injection_write
test_git_config_flag_commit_write
test_dev_null_compound
test_git_branch_mutate_writes
test_git_branch_name_no_false_positive
test_git_branch_delete_writes
test_gh_group_a_with_heredoc_classified_read
test_gh_group_a_with_redirect_still_write
test_gh_group_a_heredoc_body_with_write_pattern_is_read
test_gh_group_a_inline_body_stripping
test_git_kind_strips_quoted_args
test_git_update_ref_write
test_git_commit_subcommand_position
test_git_merge_base_read
test_git_stash_reclassify
test_quoted_arg_no_false_positive_file_op
test_interpreter_c_always_write
test_cosmetic_quote_file_op_documented_fn
test_heredoc_still_classified_after_strip
test_quoted_arg_no_false_positive_posix_redir
test_unquoted_redirect_and_tee_still_write
test_devnull_inside_command_substitution

test_dq_command_substitution_with_redirect
test_quoted_command_word_write

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
