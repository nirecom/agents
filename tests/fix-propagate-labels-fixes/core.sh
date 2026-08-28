# Core feature tests for propagate-labels.sh (#1546, #1545, #1548, #1565).
# Sourced by tests/fix-propagate-labels-fixes.sh — not run standalone.
# Tests: bin/github-issues/propagate-labels.sh
# Tags: scope:issue-specific, propagate-labels

# ===========================================================================
# T-propagate-hooksPath-neutral (#1546): the sibling clone must neutralize any
# inherited global core.hooksPath before committing (`git -C <clone> config
# core.hooksPath` set to empty), so a blocking global hook cannot abort it.
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
# T-propagate-asset-copy (#1565, revised for the sync-labels.yml exclusion):
# the 3 canonical assets (sync-labels.sh, task.yml, incident.yml) are
# git-added into the sibling clone.
# FAIL before fix: only .github/labels.yml is copied/added.
# ===========================================================================
setup_common_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
# Seed the 3 source assets in AGENTS_WORKSPACE (plus a sync-labels.yml
# workflow stub, to prove it is present in the source but deliberately never
# copied — see T-propagate-asset-workflow-excluded below).
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
for asset in "sync-labels.sh" "task.yml" "incident.yml"; do
    grep -q "add .*$asset" "$MOCK_LOG" 2>/dev/null || MISSING="$MISSING $asset"
done
if [ -z "$MISSING" ]; then
    pass "T-propagate-asset-copy: all 3 assets git-added into sibling clone"
else
    fail "T-propagate-asset-copy: not added ->$MISSING (log=$(cat "$MOCK_LOG" 2>/dev/null))"
fi

# ===========================================================================
# T-propagate-asset-workflow-excluded: .github/workflows/sync-labels.yml must
# NOT be git-added into the sibling clone. GitHub rejects a PAT-authored push
# that creates/updates a workflow file without the `workflow` scope — siblings
# don't need their own copy since propagate-labels.sh already syncs their
# labels centrally via sync-labels.sh --repo. Deliberate exclusion, so it is
# guarded positively rather than left as an absence nobody asserts on.
# Reuses the same run (same $MOCK_LOG) as T-propagate-asset-copy above.
# ===========================================================================
WORKFLOW_ADDED=0
grep -q "add .*sync-labels\.yml" "$MOCK_LOG" 2>/dev/null && WORKFLOW_ADDED=1
if [ "$WORKFLOW_ADDED" = "0" ]; then
    pass "T-propagate-asset-workflow-excluded: sync-labels.yml NOT git-added into sibling clone"
else
    fail "T-propagate-asset-workflow-excluded: sync-labels.yml was added (log=$(cat "$MOCK_LOG" 2>/dev/null))"
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

# ===========================================================================
# T-propagate-self-skip: an entry resolving to the script's own repo (per
# GITHUB_REPOSITORY) is skipped — no clone, no `gh label list`, exit 0, and
# a "self-reference" notice is printed.
# FAIL before fix: the repo is cloned and synced like any other sibling.
# ===========================================================================
setup_common_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
mkdir -p "$TMP/self-owner/self-repo"
touch "$TMP/self-owner/self-repo/.is-git-repo"
export PROPAGATE_LABELS_REPOS="$TMP/self-owner/self-repo"
export GITHUB_REPOSITORY="self-owner/self-repo"
RUN_OUT="$TMP/run-self-skip.log"
run_with_timeout 60 bash "$TARGET" >"$RUN_OUT" 2>&1
RC=$?
CLONED=0
grep -q "git clone" "$MOCK_LOG" 2>/dev/null && CLONED=1
LISTED=0
grep -q "gh label list" "$MOCK_LOG" 2>/dev/null && LISTED=1
NOTICE=0
grep -q "self-reference" "$RUN_OUT" 2>/dev/null && NOTICE=1
if [ "$RC" = "0" ] && [ "$CLONED" = "0" ] && [ "$LISTED" = "0" ] && [ "$NOTICE" = "1" ]; then
    pass "T-propagate-self-skip: self-referencing entry skipped, no clone/sync (rc=$RC)"
else
    fail "T-propagate-self-skip: rc=$RC cloned=$CLONED listed=$LISTED notice=$NOTICE (log=$(cat "$MOCK_LOG" 2>/dev/null))"
fi
unset GITHUB_REPOSITORY
teardown_common_mock

# ===========================================================================
# T-propagate-self-origin-fallback: same skip, but GITHUB_REPOSITORY unset so
# _SELF_REPO is derived from AGENTS_WORKSPACE's origin remote instead.
# FAIL before fix: the repo is cloned and synced like any other sibling.
# ===========================================================================
setup_common_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
unset GITHUB_REPOSITORY
mkdir -p "$TMP/origin-owner/origin-repo"
touch "$TMP/origin-owner/origin-repo/.is-git-repo"
export AGENTS_WORKSPACE="$TMP/origin-owner/origin-repo"
export PROPAGATE_LABELS_REPOS="$TMP/origin-owner/origin-repo"
RUN_OUT="$TMP/run-self-origin.log"
run_with_timeout 60 bash "$TARGET" >"$RUN_OUT" 2>&1
RC=$?
CLONED=0
grep -q "git clone" "$MOCK_LOG" 2>/dev/null && CLONED=1
LISTED=0
grep -q "gh label list" "$MOCK_LOG" 2>/dev/null && LISTED=1
NOTICE=0
grep -q "self-reference" "$RUN_OUT" 2>/dev/null && NOTICE=1
if [ "$RC" = "0" ] && [ "$CLONED" = "0" ] && [ "$LISTED" = "0" ] && [ "$NOTICE" = "1" ]; then
    pass "T-propagate-self-origin-fallback: origin-derived self skip works (rc=$RC)"
else
    fail "T-propagate-self-origin-fallback: rc=$RC cloned=$CLONED listed=$LISTED notice=$NOTICE (log=$(cat "$MOCK_LOG" 2>/dev/null))"
fi
teardown_common_mock

# ===========================================================================
# T-propagate-self-guard-no-overreach (regression guard): a genuinely
# different sibling still propagates normally while GITHUB_REPOSITORY names
# an unrelated repo. Guards against the guard over-skipping siblings.
# Should PASS both before and after the fix.
# ===========================================================================
setup_common_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
export GITHUB_REPOSITORY="unrelated-owner/unrelated-repo"
mkdir -p "$TMP/sibling-repo"
touch "$TMP/sibling-repo/.is-git-repo"
export PROPAGATE_LABELS_REPOS="$TMP/sibling-repo"
run_with_timeout 60 bash "$TARGET" >/dev/null 2>&1
LISTED=0
grep -q "gh label list" "$MOCK_LOG" 2>/dev/null && LISTED=1
if [ "$LISTED" = "1" ]; then
    pass "T-propagate-self-guard-no-overreach: unrelated sibling still propagates"
else
    fail "T-propagate-self-guard-no-overreach: sibling was skipped (log=$(cat "$MOCK_LOG" 2>/dev/null))"
fi
unset GITHUB_REPOSITORY
teardown_common_mock
