# tests/feature-wip-state/origin-repo-1899.sh — split test-case fragment, NOT a
# test file on its own; sourced by tests/feature-wip-state.sh.
# Tests: agents/issues/42, bin/gh, bin/github-issues/wip-state.sh, bin/workflow-plans-dir, bin/github-issues/lib/board-card.sh, bin/github-issues/lib/origin-repo.sh
# Tags: issue-create, github, workflow, issues, plans, scope:issue-specific

# ===========================================================================
# #1899 — repository identity comes from the ORIGIN remote, never `gh repo view`.
#
# Background: `gh repo view` asks the GitHub API which repository the checkout
# belongs to, and on a fork carrying both `origin` and `upstream` the API can
# answer with the upstream slug. wip-state.sh now resolves owner/repo through
# bin/github-issues/lib/origin-repo.sh instead, which reads `git remote get-url
# origin` and gates it on bin/is-github-dotcom-remote.
#
# These cases pin that contract at the wip-state.sh call site:
#   T-1899-1  origin wins over a divergent `gh repo view` answer
#   T-1899-2  no origin remote           → fail-closed, no board mutation
#   T-1899-3  non-github.com origin      → fail-closed, no board mutation
#
# "Board mutation" = any `gh project item-edit` / `gh project item-add` call in
# $GH_MOCK_ARGS_LOG.
# ===========================================================================

# ===========================================================================
# T-1899-1: set <N> from a checkout whose origin is nirecom/agents while the gh
# mock answers `gh repo view` with a DIFFERENT slug — the graphql calls must
# carry the ORIGIN repo, proving `gh repo view` is no longer consulted.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
# `gh repo view` deliberately lies: if it were still the identity source, the
# graphql calls would carry repo=otherrepo.
export GH_MOCK_OWNER_REPO="nirecom/otherrepo"
ORIGIN_CWD="$TMP/origin-cwd-agents"
make_origin_fixture "$ORIGIN_CWD" "https://github.com/nirecom/agents.git"
( cd "$ORIGIN_CWD" && run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1 )
RC=$?
HAS_ORIGIN_REPO=0; grep -q -- "repo=agents" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ORIGIN_REPO=1
HAS_VIEW_REPO=0;   grep -q -- "repo=otherrepo" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_VIEW_REPO=1
if [ "$RC" -eq 0 ] && [ "$HAS_ORIGIN_REPO" -eq 1 ] && [ "$HAS_VIEW_REPO" -eq 0 ]; then
    pass "T-1899-1: set <N> resolves owner/repo from origin remote, not 'gh repo view'"
else
    fail "T-1899-1: rc=$RC origin_repo=$HAS_ORIGIN_REPO view_repo=$HAS_VIEW_REPO log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-1899-2: set <N> from a git repo with NO origin remote → fail-closed.
# resolve_origin_owner_repo returns rc 1; no board-mutating gh call may occur.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
NOORIGIN_CWD="$TMP/no-origin-cwd"
make_git_fixture_no_origin "$NOORIGIN_CWD"
( cd "$NOORIGIN_CWD" && run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1 )
RC=$?
MUTATED=0; grep -qE -- "project item-(edit|add) " "$GH_MOCK_ARGS_LOG" 2>/dev/null && MUTATED=1
if [ "$RC" -ne 0 ] && [ "$MUTATED" -eq 0 ]; then
    pass "T-1899-2: set <N> with no origin remote → fail-closed, no board mutation"
else
    fail "T-1899-2: rc=$RC mutated=$MUTATED log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-1899-3: set <N> from a git repo whose origin is a non-github.com host →
# fail-closed. is-github-dotcom-remote rejects it (resolver rc 2); no board
# mutation may occur.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
NONGH_CWD="$TMP/non-github-origin-cwd"
make_origin_fixture "$NONGH_CWD" "https://gitlab.com/nirecom/agents.git"
( cd "$NONGH_CWD" && run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1 )
RC=$?
MUTATED=0; grep -qE -- "project item-(edit|add) " "$GH_MOCK_ARGS_LOG" 2>/dev/null && MUTATED=1
if [ "$RC" -ne 0 ] && [ "$MUTATED" -eq 0 ]; then
    pass "T-1899-3: set <N> with non-github.com origin → fail-closed, no board mutation"
else
    fail "T-1899-3: rc=$RC mutated=$MUTATED log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock
