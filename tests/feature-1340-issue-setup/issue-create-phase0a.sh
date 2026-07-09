#!/bin/bash
# tests/feature-1340-issue-setup/issue-create-phase0a.sh
# Tests: bin/github-issues/issue-create.sh, bin/github-issues/issue-create-preflight.sh, bin/github-issues/sync-labels.sh
# Tags: issue-setup, issue-create, github-issues, scope:issue-specific
#
# Tests for issue-create.sh Phase 0a label auto-repair (step 6 of #1340).
# L2: preflight --check-labels rc=1 + sync-labels success → gh issue create proceeds;
#     sync-labels failure → issue-create.sh exits 1;
#     --check-labels rc=0 → sync-labels NOT called;
#     AGENTS_CONFIG_DIR unset → Phase 0a skipped with warn, issue-create continues.
#
# L3 gap (what this test does NOT catch):
# - Whether Phase 0a correctly integrates with a live GitHub API call chain
#   (real network, real label 422 errors).
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# pass / fail / AGENTS_DIR provided by _lib.sh.
export AGENTS_DIR
TARGET_IC="$AGENTS_DIR/bin/github-issues/issue-create.sh"

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin" "$TMP/agents-config/bin"

    # Default mock knobs
    : "${GH_MOCK_LABELS_HAVE_TASK:=1}"
    : "${GH_MOCK_SYNC_LABELS_FAIL:=0}"
    : "${GH_MOCK_CREATE_ISSUE_FAIL:=0}"

    # Create mock issue-create-preflight.sh — logs its invocation so tests can
    # assert POSITIVE evidence that Phase 0a actually ran the preflight.
    cat > "$TMP/agents-config/bin/issue-create-preflight.sh" <<'PREFLIGHT_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${MOCK_LOG:-}" ]; then
    printf 'preflight called: %s\n' "$ARGS" >> "$MOCK_LOG"
fi
case "$ARGS" in
  *--check-labels*)
    # Hard-failure mode (C3): gh/preflight itself errors → exit 2, which is
    # DISTINCT from the rc=1 "type:task absent" verdict. Phase 0a must fail-closed.
    if [ "${GH_MOCK_PREFLIGHT_HARD_FAIL:-0}" = "1" ]; then
        echo "error: preflight hard failure (simulated)" >&2
        exit 2
    fi
    if [ "${GH_MOCK_LABELS_HAVE_TASK:-1}" = "1" ]; then
        exit 0  # type:task present
    else
        exit 1  # type:task absent
    fi
    ;;
  *--check-project*)
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
PREFLIGHT_EOF
    chmod +x "$TMP/agents-config/bin/issue-create-preflight.sh"

    # Create mock sync-labels.sh
    cat > "$TMP/agents-config/bin/sync-labels.sh" <<'SYNC_EOF'
#!/bin/bash
if [ -n "${MOCK_LOG:-}" ]; then
    printf 'sync-labels called: %s\n' "$*" >> "$MOCK_LOG"
fi
if [ "${GH_MOCK_SYNC_LABELS_FAIL:-0}" = "1" ]; then
    echo "error: sync-labels failed" >&2
    exit 1
fi
echo "labels synced"
exit 0
SYNC_EOF
    chmod +x "$TMP/agents-config/bin/sync-labels.sh"

    # Create mock gh
    cat > "$TMP/mock-bin/gh" <<'GH_MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${MOCK_LOG:-}" ]; then
    printf '%s\n' "gh $ARGS" >> "$MOCK_LOG"
fi
case "$ARGS" in
  auth\ status*)
    echo "Logged in to github.com as testuser"
    echo "Token scopes: 'repo', 'project'"
    exit 0
    ;;
  repo\ view\ *)
    echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"
    exit 0
    ;;
  api\ graphql\ *projectsV2*)
    printf '{"id":"PVT_mock","number":1,"ownerLogin":"nirecom"}\n'
    exit 0
    ;;
  api\ graphql*)
    echo "false"; exit 0
    ;;
  issue\ create*)
    if [ "${GH_MOCK_CREATE_ISSUE_FAIL:-0}" = "1" ]; then
        echo "error: gh issue create failed" >&2; exit 1
    fi
    echo "https://github.com/nirecom/agents/issues/999"
    exit 0
    ;;
  *)
    echo "MOCK GH: no match: $ARGS" >&2; exit 0
    ;;
esac
GH_MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"

    # Mock is-github-dotcom-remote
    cat > "$TMP/mock-bin/bin" <<'REMOTE_EOF'
#!/bin/bash
# Placeholder — is-github-dotcom-remote is at $AGENTS_DIR/bin/is-github-dotcom-remote
exit 0
REMOTE_EOF
    # The actual is-github-dotcom-remote check in issue-create.sh uses the agents bin
    # We create a mock in mock-bin that returns rc=0 (is GitHub)
    cat > "$TMP/mock-bin/is-github-dotcom-remote" <<'REMOTE_EOF'
#!/bin/bash
exit "${GH_MOCK_IS_GITHUB_REMOTE:-0}"
REMOTE_EOF
    chmod +x "$TMP/mock-bin/is-github-dotcom-remote"

    export PATH="$TMP/mock-bin:$PATH"
    export MOCK_LOG="$TMP/mock.log"
    : > "$MOCK_LOG"
    export WORKFLOW_PLANS_DIR="$TMP/plans"
    # AGENTS_CONFIG_DIR points to TMP — mock scripts live under bin/github-issues/
    export AGENTS_CONFIG_DIR="$TMP/agents-config"
    mkdir -p "$AGENTS_CONFIG_DIR/bin/github-issues" "$AGENTS_CONFIG_DIR/.github"
    touch "$AGENTS_CONFIG_DIR/.github/labels.yml"

    # Phase 0a calls: bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-create-preflight.sh"
    # and:           bash "$AGENTS_CONFIG_DIR/bin/github-issues/sync-labels.sh"
    # Place mock scripts at those exact paths.
    cp "$TMP/agents-config/bin/issue-create-preflight.sh" \
       "$AGENTS_CONFIG_DIR/bin/github-issues/issue-create-preflight.sh" 2>/dev/null || true
    cp "$TMP/agents-config/bin/sync-labels.sh" \
       "$AGENTS_CONFIG_DIR/bin/github-issues/sync-labels.sh" 2>/dev/null || true
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset MOCK_LOG WORKFLOW_PLANS_DIR AGENTS_CONFIG_DIR \
          GH_MOCK_LABELS_HAVE_TASK GH_MOCK_SYNC_LABELS_FAIL \
          GH_MOCK_CREATE_ISSUE_FAIL GH_MOCK_OWNER_REPO \
          GH_MOCK_PREFLIGHT_HARD_FAIL \
          GH_MOCK_IS_GITHUB_REMOTE 2>/dev/null || true
}

# Issue body with required Background + Changes fields
VALID_BODY="Background: test background.
Changes: test changes."

# Positive-evidence helper: was the preflight actually invoked?
preflight_invoked() { grep -q "preflight called" "$MOCK_LOG" 2>/dev/null; }

# ===========================================================================
# TICA-1: preflight rc=1 (type:task absent) + sync-labels succeeds → issue create proceeds.
# POSITIVE evidence: preflight WAS invoked AND sync-labels WAS invoked AND gh
# issue create WAS invoked. RED now: Phase 0a absent → preflight never runs.
# ===========================================================================
setup_mock
export GH_MOCK_LABELS_HAVE_TASK=0
export GH_MOCK_SYNC_LABELS_FAIL=0

STDERR_FILE="$TMP/tica1-stderr.log"
RC=0
OUT=$(ISSUE_CREATE_SKIP_SCHEMA=1 bash "$TARGET_IC" \
    --title "Test issue" \
    --body "$VALID_BODY" \
    2>"$STDERR_FILE") || RC=$?

ISSUE_CREATE_CALLED=0
grep -q "issue create" "$MOCK_LOG" 2>/dev/null && ISSUE_CREATE_CALLED=1
SYNC_LABELS_CALLED=0
grep -q "sync-labels called" "$MOCK_LOG" 2>/dev/null && SYNC_LABELS_CALLED=1
PREFLIGHT_CALLED=0
preflight_invoked && PREFLIGHT_CALLED=1

if [ "$RC" = "0" ] && [ "$PREFLIGHT_CALLED" = "1" ] && [ "$SYNC_LABELS_CALLED" = "1" ] && [ "$ISSUE_CREATE_CALLED" = "1" ]; then
    pass "TICA-1: label absent → preflight ran → sync-labels ran → issue create proceeds"
else
    fail "TICA-1: rc=$RC preflight=$PREFLIGHT_CALLED sync=$SYNC_LABELS_CALLED create=$ISSUE_CREATE_CALLED — expected RED (Phase 0a not yet implemented)"
fi
teardown_mock

# ===========================================================================
# TICA-2: preflight rc=1 + sync-labels FAILS → issue-create exits non-zero.
# POSITIVE evidence: preflight WAS invoked AND sync-labels WAS invoked AND
# gh issue create was NOT invoked. RED now: Phase 0a absent.
# ===========================================================================
setup_mock
export GH_MOCK_LABELS_HAVE_TASK=0
export GH_MOCK_SYNC_LABELS_FAIL=1

STDERR_FILE="$TMP/tica2-stderr.log"
RC=0
OUT=$(ISSUE_CREATE_SKIP_SCHEMA=1 bash "$TARGET_IC" \
    --title "Test issue" \
    --body "$VALID_BODY" \
    2>"$STDERR_FILE") || RC=$?

ISSUE_CREATE_CALLED=0
grep -q "issue create" "$MOCK_LOG" 2>/dev/null && ISSUE_CREATE_CALLED=1
SYNC_LABELS_CALLED=0
grep -q "sync-labels called" "$MOCK_LOG" 2>/dev/null && SYNC_LABELS_CALLED=1
PREFLIGHT_CALLED=0
preflight_invoked && PREFLIGHT_CALLED=1

if [ "$RC" != "0" ] && [ "$PREFLIGHT_CALLED" = "1" ] && [ "$SYNC_LABELS_CALLED" = "1" ] && [ "$ISSUE_CREATE_CALLED" = "0" ]; then
    pass "TICA-2: preflight ran → sync-labels failed → issue-create exits non-zero, no gh issue create"
else
    fail "TICA-2: rc=$RC preflight=$PREFLIGHT_CALLED sync=$SYNC_LABELS_CALLED create=$ISSUE_CREATE_CALLED — expected RED (Phase 0a not yet implemented)"
fi
teardown_mock

# ===========================================================================
# TICA-3: preflight rc=0 (type:task present) → sync-labels NOT called.
# POSITIVE evidence: preflight WAS invoked (proves Phase 0a ran), sync-labels
# was NOT invoked, and gh issue create WAS invoked. The "preflight invoked"
# assertion makes this RED now (Phase 0a absent → preflight never runs) and
# green post-implementation — removing the former vacuous pass.
# ===========================================================================
setup_mock
export GH_MOCK_LABELS_HAVE_TASK=1
export GH_MOCK_SYNC_LABELS_FAIL=0

STDERR_FILE="$TMP/tica3-stderr.log"
RC=0
OUT=$(ISSUE_CREATE_SKIP_SCHEMA=1 bash "$TARGET_IC" \
    --title "Test issue" \
    --body "$VALID_BODY" \
    2>"$STDERR_FILE") || RC=$?

SYNC_LABELS_CALLED=0
grep -q "sync-labels called" "$MOCK_LOG" 2>/dev/null && SYNC_LABELS_CALLED=1
ISSUE_CREATE_CALLED=0
grep -q "issue create" "$MOCK_LOG" 2>/dev/null && ISSUE_CREATE_CALLED=1
PREFLIGHT_CALLED=0
preflight_invoked && PREFLIGHT_CALLED=1

if [ "$RC" = "0" ] && [ "$PREFLIGHT_CALLED" = "1" ] && [ "$SYNC_LABELS_CALLED" = "0" ] && [ "$ISSUE_CREATE_CALLED" = "1" ]; then
    pass "TICA-3: preflight ran (rc=0) → sync-labels NOT called → issue create proceeds"
else
    fail "TICA-3: rc=$RC preflight=$PREFLIGHT_CALLED sync=$SYNC_LABELS_CALLED create=$ISSUE_CREATE_CALLED — expected RED (Phase 0a not yet implemented)"
fi
teardown_mock

# ===========================================================================
# TICA-4: AGENTS_CONFIG_DIR unset → Phase 0a skipped WITH a stderr warning,
# and issue creation still proceeds (backward compat). C10: assert the warning
# is actually emitted — not just that creation proceeds. RED now: Phase 0a
# absent → no skip-warning is emitted. Green post-implementation.
# ===========================================================================
setup_mock
unset AGENTS_CONFIG_DIR
export GH_MOCK_LABELS_HAVE_TASK=0

STDERR_FILE="$TMP/tica4-stderr.log"
RC=0
OUT=$(ISSUE_CREATE_SKIP_SCHEMA=1 bash "$TARGET_IC" \
    --title "Test issue" \
    --body "$VALID_BODY" \
    2>"$STDERR_FILE") || RC=$?

STDERR_CONTENT=$(cat "$STDERR_FILE" 2>/dev/null)
ISSUE_CREATE_CALLED=0
grep -q "issue create" "$MOCK_LOG" 2>/dev/null && ISSUE_CREATE_CALLED=1
# Phase 0a must warn that it is skipping label auto-repair due to missing config.
WARN_EMITTED=0
echo "$STDERR_CONTENT" | grep -qiE "AGENTS_CONFIG_DIR|label auto-repair|phase 0a|skipping label" && WARN_EMITTED=1

if [ "$RC" = "0" ] && [ "$ISSUE_CREATE_CALLED" = "1" ] && [ "$WARN_EMITTED" = "1" ]; then
    pass "TICA-4: AGENTS_CONFIG_DIR unset → skip warning emitted; issue create continues (rc=0)"
else
    fail "TICA-4: rc=$RC create=$ISSUE_CREATE_CALLED warn=$WARN_EMITTED — expected RED (Phase 0a skip-warning not yet implemented) stderr=$STDERR_CONTENT"
fi
teardown_mock

# ===========================================================================
# TICA-5 (C2): two-run idempotency. Run 1: labels ABSENT (preflight rc=1) →
# sync-labels called once + gh issue create proceeds. Run 2 (same process, mock
# now reports labels PRESENT / preflight rc=0) → sync-labels NOT called again +
# gh issue create still proceeds. Both runs share one MOCK_LOG so call counts
# accumulate. Asserted via MOCK_LOG counts.
# ===========================================================================
setup_mock
export GH_MOCK_SYNC_LABELS_FAIL=0

# --- Run 1: labels absent → auto-repair fires ---
export GH_MOCK_LABELS_HAVE_TASK=0
RC1=0
ISSUE_CREATE_SKIP_SCHEMA=1 bash "$TARGET_IC" --title "Run one" --body "$VALID_BODY" >/dev/null 2>&1 || RC1=$?

# --- Run 2: labels now present → no second sync ---
export GH_MOCK_LABELS_HAVE_TASK=1
RC2=0
ISSUE_CREATE_SKIP_SCHEMA=1 bash "$TARGET_IC" --title "Run two" --body "$VALID_BODY" >/dev/null 2>&1 || RC2=$?

SYNC_COUNT=$(grep -c "sync-labels called" "$MOCK_LOG" 2>/dev/null); SYNC_COUNT="${SYNC_COUNT:-0}"
CREATE_COUNT=$(grep -c "issue create" "$MOCK_LOG" 2>/dev/null); CREATE_COUNT="${CREATE_COUNT:-0}"
if [ "$RC1" = "0" ] && [ "$RC2" = "0" ] \
   && [ "$SYNC_COUNT" = "1" ] && [ "$CREATE_COUNT" = "2" ]; then
    pass "TICA-5 (C2): two-run — sync-labels once (run1 only), issue create twice"
else
    fail "TICA-5 (C2): rc1=$RC1 rc2=$RC2 sync_count=$SYNC_COUNT create_count=$CREATE_COUNT — expected RED (Phase 0a not yet implemented)"
fi
teardown_mock

# ===========================================================================
# TICA-6 (C3): preflight HARD-FAILURE distinct from rc=1. Mock preflight
# --check-labels exits 2 (error, not the "absent" verdict) → sync-labels is NOT
# invoked AND issue creation fails closed (issue-create.sh exits non-zero).
# Mirrors the fail-closed principle already applied for gh-failure inside preflight.
# ===========================================================================
setup_mock
export GH_MOCK_PREFLIGHT_HARD_FAIL=1
STDERR_FILE="$TMP/tica6-stderr.log"
RC=0
ISSUE_CREATE_SKIP_SCHEMA=1 bash "$TARGET_IC" --title "Test issue" --body "$VALID_BODY" >/dev/null 2>"$STDERR_FILE" || RC=$?
SYNC_CALLED=0
grep -q "sync-labels called" "$MOCK_LOG" 2>/dev/null && SYNC_CALLED=1
ISSUE_CREATE_CALLED=0
grep -q "issue create" "$MOCK_LOG" 2>/dev/null && ISSUE_CREATE_CALLED=1
if [ "$RC" != "0" ] && [ "$SYNC_CALLED" = "0" ] && [ "$ISSUE_CREATE_CALLED" = "0" ]; then
    pass "TICA-6 (C3): preflight hard-fail (rc=2) → fail-closed, no sync, no issue create"
else
    fail "TICA-6 (C3): rc=$RC sync=$SYNC_CALLED create=$ISSUE_CREATE_CALLED — expected RED (Phase 0a fail-closed not yet implemented)"
fi
teardown_mock

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
