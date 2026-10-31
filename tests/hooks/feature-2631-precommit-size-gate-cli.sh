#!/usr/bin/env bash
# tests/hooks/feature-2631-precommit-size-gate-cli.sh
# Tests: bin/size-check
# Tags: scope:issue-specific, size-limits, cli, git, block, shrink, layer:TL2, fail-closed, env-override
# #2631 L9: the bin/size-check CLI contract (records, --pre/--post, rc 0-3) run directly. Split by
# runtime from feature-2631-precommit-size-gate.sh; the bodies live in its sibling folder.
# TL3 gap (what this test does NOT catch):
# - hooks/pre-commit and the review bins reading these records in a live checkout
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"
harness_assert_isolated
unset CLAUDE_CODE_SESSION_ID CODE_FILE_EXTENSIONS 2>/dev/null || true
export CONFIRM_INTENT=on CONFIRM_OUTLINE=on CONFIRM_DETAIL=on COMMENT_BLOCK_ENFORCE=on
# shellcheck source=feature-2631-precommit-size-gate/fixture.sh
. "$ROOT/tests/hooks/feature-2631-precommit-size-gate/fixture.sh"
# shellcheck source=feature-2631-precommit-size-gate/size-check-cli.sh
. "$ROOT/tests/hooks/feature-2631-precommit-size-gate/size-check-cli.sh"

case_begin "size-check-kind-worktree-records" "bin/size-check"
sc_case_kind_worktree_records
case_end

case_begin "size-check-pre-rev-and-new-blob" "bin/size-check"
sc_case_pre_rev_and_new_blob
case_end

case_begin "size-check-post-index-reads-the-staged-blob" "bin/size-check"
sc_case_post_index_reads_the_staged_blob
case_end

case_begin "size-check-pre-rev-with-post-index-ignores-the-worktree" "bin/size-check"
sc_case_pre_rev_with_post_index_ignores_the_worktree
case_end

case_begin "size-check-input-edges" "bin/size-check"
sc_case_input_edges
case_end

case_begin "size-check-kind-prompt-and-docs-filters" "bin/size-check"
sc_case_kind_prompt_and_docs_filters
case_end

case_begin "size-check-usage-and-infrastructure-errors" "bin/size-check"
sc_case_usage_and_infrastructure_errors
case_end

case_begin "size-check-staged-auto-ignores-env-extensions" "bin/size-check"
sc_case_staged_auto_ignores_env_extensions
case_end

case_begin "size-check-staged-auto-follows-dotenv-extensions" "bin/size-check"
sc_case_staged_auto_follows_dotenv_extensions
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
