# tests/feature-wip-state/origin-repo-1899.sh — split test-case fragment, NOT a
# test file on its own; sourced by tests/feature-wip-state.sh.
# Tests: agents/issues/42, bin/gh, bin/github-issues/wip-state.sh, bin/workflow-plans-dir, bin/github-issues/lib/board-card.sh, bin/github-issues/lib/origin-repo.sh
# Tags: issue-create, github, workflow, issues, plans, scope:issue-specific

# ===========================================================================
# #1899 — wip-state.sh resolves owner/repo from the ORIGIN remote (via
# bin/github-issues/lib/origin-repo.sh), never `gh repo view`.
#   T-1899-1  origin wins over a divergent `gh repo view` answer
#   T-1899-2  no origin remote      → fail-closed, no board mutation
#   T-1899-3  non-github.com origin → fail-closed, no board mutation
# "Board mutation" = any `gh project item-edit`/`item-add` in $GH_MOCK_ARGS_LOG.
# ===========================================================================

# ===========================================================================
# T-1899-1: origin=mock-owner/mock-repo, `gh repo view` mock lies with a
# different slug — graphql calls must carry the ORIGIN repo, not the
# `gh repo view` one.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_OWNER_REPO="mock-owner/other-repo"
ORIGIN_CWD="$TMP/origin-cwd-mock-repo"
make_origin_fixture "$ORIGIN_CWD" "https://github.com/mock-owner/mock-repo.git"
( cd "$ORIGIN_CWD" && run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1 )
RC=$?
HAS_ORIGIN_REPO=0; grep -q -- "repo=mock-repo" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ORIGIN_REPO=1
HAS_VIEW_REPO=0;   grep -q -- "repo=other-repo" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_VIEW_REPO=1
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
make_origin_fixture "$NONGH_CWD" "https://gitlab.com/mock-owner/mock-repo.git"
( cd "$NONGH_CWD" && run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1 )
RC=$?
MUTATED=0; grep -qE -- "project item-(edit|add) " "$GH_MOCK_ARGS_LOG" 2>/dev/null && MUTATED=1
if [ "$RC" -ne 0 ] && [ "$MUTATED" -eq 0 ]; then
    pass "T-1899-3: set <N> with non-github.com origin → fail-closed, no board mutation"
else
    fail "T-1899-3: rc=$RC mutated=$MUTATED log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock
