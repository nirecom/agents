# tests/feature-1261-labels-ssot/propagate-labels-ci/_tests-ci-fallback.sh
# CI fallback test cases for propagate-labels.sh (T-propagate-ci-fallback-*)

# ===========================================================================
# T-propagate-ci-fallback-1: non-existent path in CI → fallback via AGENTS_WORKSPACE owner
# Current code: git -C /nonexistent fails with no fallback → expected to FAIL (fail-before-fix)
# ===========================================================================
setup_mock
mkdir -p "$TMP/repos/testorg/agents"
export AGENTS_WORKSPACE="$TMP/repos/testorg/agents"
export PROPAGATE_LABELS_REPOS="/nonexistent/path/myrepo"
export PROPAGATE_LABELS_PAT="test-pat-fallback1"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
run_with_timeout 30 bash "$TARGET" >/dev/null 2>&1
RC=$?
CLONE_HAS_PATH=0
grep "git clone" "$MOCK_LOG" 2>/dev/null | grep -q "testorg/myrepo" && CLONE_HAS_PATH=1
if [ "$CLONE_HAS_PATH" = "1" ] && [ "$RC" = "0" ]; then
    pass "T-propagate-ci-fallback-1: non-existent path → fallback clone via AGENTS_WORKSPACE owner"
else
    fail "T-propagate-ci-fallback-1: rc=$RC clone_has_path=$CLONE_HAS_PATH log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-propagate-ci-fallback-2: non-existent path → PAT-embedded clone URL uses fallback owner
# Current code: git -C /nonexistent fails with no fallback → expected to FAIL (fail-before-fix)
# ===========================================================================
setup_mock
mkdir -p "$TMP/repos/nirecom/agents-ws"
export AGENTS_WORKSPACE="$TMP/repos/nirecom/agents-ws"
export PROPAGATE_LABELS_REPOS="/nonexistent/path/dotfiles"
export PROPAGATE_LABELS_PAT="test-pat-fallback2"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
run_with_timeout 30 bash "$TARGET" >/dev/null 2>&1
RC=$?
CLONE_HAS_REPO=0
grep "git clone" "$MOCK_LOG" 2>/dev/null | grep -q "nirecom/dotfiles" && CLONE_HAS_REPO=1
CLONE_HAS_PAT=0
grep "git clone" "$MOCK_LOG" 2>/dev/null | grep -q "x-access-token:test-pat-fallback2" && CLONE_HAS_PAT=1
teardown_mock
if [ "$CLONE_HAS_REPO" = "1" ] && [ "$CLONE_HAS_PAT" = "1" ]; then
    pass "T-propagate-ci-fallback-2: non-existent path → fallback clone has owner+PAT"
else
    fail "T-propagate-ci-fallback-2: clone_has_repo=$CLONE_HAS_REPO clone_has_pat=$CLONE_HAS_PAT log=<see above>"
fi
