# Core feature tests for propagate-labels.sh (#1546, #1545, #1548, #1565).
# Sourced by tests/fix-propagate-labels-fixes.sh — not run standalone.

# ===========================================================================
# T-propagate-hooksPath-neutral (#1546): the sibling clone must neutralize any
# inherited global core.hooksPath before committing, so a blocking global hook
# cannot abort the propagation commit. Structural assertion: a
# `git -C <clone> config core.hooksPath` (set to empty) is logged.
# FAIL before fix: propagate-labels.sh never sets core.hooksPath.
# ===========================================================================
setup_common_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
mkdir -p "$TMP/sibling-repo"
touch "$TMP/sibling-repo/.is-git-repo"
export PROPAGATE_LABELS_REPOS="$TMP/sibling-repo"
export GIT_DIFF_RC=1   # force a commit so the hooksPath neutralization matters
run_with_timeout 60 bash "$TARGET" >/dev/null 2>&1
HOOKS_NEUTRALIZED=0
grep -Eq "config core\.hooksPath" "$MOCK_LOG" 2>/dev/null && HOOKS_NEUTRALIZED=1
if [ "$HOOKS_NEUTRALIZED" = "1" ]; then
    pass "T-propagate-hooksPath-neutral: clone neutralizes core.hooksPath before commit"
else
    fail "T-propagate-hooksPath-neutral: core.hooksPath never set (log=$(cat "$MOCK_LOG" 2>/dev/null))"
fi
teardown_common_mock

# ===========================================================================
# T-propagate-pat-absent-fallback (#1545): PROPAGATE_LABELS_PAT unset, but
# `gh auth token` yields a token → propagation must proceed (reach sync-labels
# via `gh label list`) instead of exiting early.
# FAIL before fix: script exits 0 immediately when PAT unset.
# ===========================================================================
setup_common_mock
unset PROPAGATE_LABELS_PAT
export GH_MOCK_AUTH_TOKEN="fallback-token-abcde"
mkdir -p "$TMP/sibling-repo"
touch "$TMP/sibling-repo/.is-git-repo"
export PROPAGATE_LABELS_REPOS="$TMP/sibling-repo"
run_with_timeout 60 bash "$TARGET" >/dev/null 2>&1
PROCEEDED=0
grep -q "gh label list" "$MOCK_LOG" 2>/dev/null && PROCEEDED=1
if [ "$PROCEEDED" = "1" ]; then
    pass "T-propagate-pat-absent-fallback: gh auth token fallback drives propagation"
else
    fail "T-propagate-pat-absent-fallback: propagation did not proceed (log=$(cat "$MOCK_LOG" 2>/dev/null))"
fi
teardown_common_mock

# ===========================================================================
# T-propagate-pat-absent-no-token (#1545 edge): PROPAGATE_LABELS_PAT unset and
# `gh auth token` empty → graceful skip (exit 0), no propagation.
# May PASS today (current behavior exits 0 when PAT unset).
# ===========================================================================
setup_common_mock
unset PROPAGATE_LABELS_PAT
export GH_MOCK_AUTH_TOKEN=""
mkdir -p "$TMP/sibling-repo"
touch "$TMP/sibling-repo/.is-git-repo"
export PROPAGATE_LABELS_REPOS="$TMP/sibling-repo"
run_with_timeout 60 bash "$TARGET" >/dev/null 2>&1
RC=$?
if [ "$RC" = "0" ]; then
    pass "T-propagate-pat-absent-no-token: graceful skip (exit 0) when no token available"
else
    fail "T-propagate-pat-absent-no-token: exit=$RC (expected 0)"
fi
teardown_common_mock

# ===========================================================================
# T-propagate-depth1-scan (#1548): PROPAGATE_LABELS_REPOS points to a parent dir
# containing 2 git repos → sync-labels.sh called for each (2 `gh label list`).
# FAIL before fix: parent dir is treated as a single repo (1 or 0 calls).
# ===========================================================================
setup_common_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
mkdir -p "$TMP/parent-dir/repo-a" "$TMP/parent-dir/repo-b"
touch "$TMP/parent-dir/repo-a/.is-git-repo" "$TMP/parent-dir/repo-b/.is-git-repo"
# parent-dir itself is NOT a git repo (no marker) → depth-1 scan required.
export PROPAGATE_LABELS_REPOS="$TMP/parent-dir"
run_with_timeout 60 bash "$TARGET" >/dev/null 2>&1
LIST_COUNT=$(grep -c "gh label list" "$MOCK_LOG" 2>/dev/null)
LIST_COUNT="${LIST_COUNT:-0}"
if [ "$LIST_COUNT" = "2" ]; then
    pass "T-propagate-depth1-scan: parent dir with 2 repos syncs both (count=$LIST_COUNT)"
else
    fail "T-propagate-depth1-scan: expected 2 sync-labels invocations, got $LIST_COUNT (log=$(cat "$MOCK_LOG" 2>/dev/null))"
fi
teardown_common_mock

# ===========================================================================
# T-propagate-depth1-direct-repo (#1548 regression): direct git repo path still
# works — 1 sync-labels invocation. Should PASS already.
# ===========================================================================
setup_common_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
# Two-level path so the ci-style git mock resolves owner/repo from the parents.
mkdir -p "$TMP/direct/myrepo"
touch "$TMP/direct/myrepo/.is-git-repo"
export PROPAGATE_LABELS_REPOS="$TMP/direct/myrepo"
run_with_timeout 60 bash "$TARGET" >/dev/null 2>&1
LIST_COUNT=$(grep -c "gh label list" "$MOCK_LOG" 2>/dev/null)
LIST_COUNT="${LIST_COUNT:-0}"
if [ "$LIST_COUNT" = "1" ]; then
    pass "T-propagate-depth1-direct-repo: direct repo still syncs once (count=$LIST_COUNT)"
else
    fail "T-propagate-depth1-direct-repo: expected 1 sync-labels invocation, got $LIST_COUNT (log=$(cat "$MOCK_LOG" 2>/dev/null))"
fi
teardown_common_mock

# ===========================================================================
# T-propagate-depth1-empty-parent (#1548 edge): parent dir with no git repos →
# graceful skip (exit 0), no sync-labels invocation.
# FAIL before fix: parent dir treated as a repo → resolves + syncs anyway.
# ===========================================================================
setup_common_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
mkdir -p "$TMP/empty-parent"
# No .is-git-repo marker anywhere under empty-parent.
export PROPAGATE_LABELS_REPOS="$TMP/empty-parent"
run_with_timeout 60 bash "$TARGET" >/dev/null 2>&1
RC=$?
LIST_COUNT=$(grep -c "gh label list" "$MOCK_LOG" 2>/dev/null)
LIST_COUNT="${LIST_COUNT:-0}"
if [ "$RC" = "0" ] && [ "$LIST_COUNT" = "0" ]; then
    pass "T-propagate-depth1-empty-parent: empty parent skips gracefully (rc=$RC count=$LIST_COUNT)"
else
    fail "T-propagate-depth1-empty-parent: rc=$RC count=$LIST_COUNT (expected rc=0 count=0)"
fi
teardown_common_mock

# ===========================================================================
# T-propagate-asset-copy (#1565): the 4 canonical assets (sync-labels.sh,
# task.yml, incident.yml, sync-labels.yml) are git-added into the sibling clone.
# FAIL before fix: only .github/labels.yml is copied/added.
# ===========================================================================
setup_common_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
# Seed the 4 source assets in AGENTS_WORKSPACE.
mkdir -p "$TMP/agents-workspace/bin/github-issues" \
         "$TMP/agents-workspace/.github/ISSUE_TEMPLATE" \
         "$TMP/agents-workspace/.github/workflows"
echo "#!/bin/bash" > "$TMP/agents-workspace/bin/github-issues/sync-labels.sh"
echo "name: task" > "$TMP/agents-workspace/.github/ISSUE_TEMPLATE/task.yml"
echo "name: incident" > "$TMP/agents-workspace/.github/ISSUE_TEMPLATE/incident.yml"
echo "name: sync-labels" > "$TMP/agents-workspace/.github/workflows/sync-labels.yml"
export AGENTS_WORKSPACE="$TMP/agents-workspace"
mkdir -p "$TMP/sibling-repo"
touch "$TMP/sibling-repo/.is-git-repo"
export PROPAGATE_LABELS_REPOS="$TMP/sibling-repo"
run_with_timeout 60 bash "$TARGET" >/dev/null 2>&1
MISSING=""
for asset in "sync-labels.sh" "task.yml" "incident.yml" "sync-labels.yml"; do
    grep -q "add .*$asset" "$MOCK_LOG" 2>/dev/null || MISSING="$MISSING $asset"
done
if [ -z "$MISSING" ]; then
    pass "T-propagate-asset-copy: all 4 assets git-added into sibling clone"
else
    fail "T-propagate-asset-copy: not added ->$MISSING (log=$(cat "$MOCK_LOG" 2>/dev/null))"
fi
teardown_common_mock

# ===========================================================================
# T-propagate-asset-missing-source (#1565 error): one source asset absent →
# graceful handling (exit 0, no crash), remaining assets still processed.
# FAIL before fix: asset-copy path not implemented.
# ===========================================================================
setup_common_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
mkdir -p "$TMP/agents-workspace/bin/github-issues" \
         "$TMP/agents-workspace/.github/ISSUE_TEMPLATE" \
         "$TMP/agents-workspace/.github/workflows"
# sync-labels.sh intentionally absent.
echo "name: task" > "$TMP/agents-workspace/.github/ISSUE_TEMPLATE/task.yml"
echo "name: incident" > "$TMP/agents-workspace/.github/ISSUE_TEMPLATE/incident.yml"
echo "name: sync-labels" > "$TMP/agents-workspace/.github/workflows/sync-labels.yml"
export AGENTS_WORKSPACE="$TMP/agents-workspace"
mkdir -p "$TMP/sibling-repo"
touch "$TMP/sibling-repo/.is-git-repo"
export PROPAGATE_LABELS_REPOS="$TMP/sibling-repo"
run_with_timeout 60 bash "$TARGET" >/dev/null 2>&1
RC=$?
# Graceful: no crash (exit 0) AND a remaining asset (task.yml) still git-added.
TASK_ADDED=0
grep -q "add .*task.yml" "$MOCK_LOG" 2>/dev/null && TASK_ADDED=1
if [ "$RC" = "0" ] && [ "$TASK_ADDED" = "1" ]; then
    pass "T-propagate-asset-missing-source: missing asset handled gracefully, others processed"
else
    fail "T-propagate-asset-missing-source: rc=$RC task_added=$TASK_ADDED (log=$(cat "$MOCK_LOG" 2>/dev/null))"
fi
teardown_common_mock
