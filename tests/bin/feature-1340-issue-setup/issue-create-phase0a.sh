#!/bin/bash
# tests/bin/feature-1340-issue-setup/issue-create-phase0a.sh
# Tests: bin/github-issues/issue-create.sh, bin/github-issues/issue-create-preflight.sh, bin/github-issues/sync-labels.sh
# Tags: issue-setup, issue-create, github-issues, scope:issue-specific
# issue-create.sh Phase 0a label auto-repair (#1340 step 6). L2: --check-labels rc=1 + sync ok → create proceeds;
# sync failure → exit 1; --check-labels rc=0 → sync NOT called; no root env var at all → Phase 0a still runs.
# L3 gap: live GitHub API call chain (real network, real label 422 errors).
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: skill-orchestration.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Top-level dual pin (rules/test/fixture-isolation.md): covers every line that runs
# outside a case; setup_mock re-points both under its own $TMP, teardown_mock restores.
_PHASE0A_TMP_ROOT="$(mktemp -d)"; readonly _PHASE0A_TMP_ROOT
trap 'rm -rf "$_PHASE0A_TMP_ROOT"' EXIT
mkdir -p "$_PHASE0A_TMP_ROOT/workflow-state" "$_PHASE0A_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_PHASE0A_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_PHASE0A_TMP_ROOT/plans"

# pass / fail / __LIB_SCRIPT_CHECKOUT_ROOT provided by _lib.sh.
# shellcheck source=../../lib/script-checkout-fixture.sh
. "$__LIB_SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"
TARGET_IC_REL="bin/github-issues/issue-create.sh"

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    # issue-create.sh resolves the preflight, sync-labels and scanner from its
    # own checkout, so it runs as a copy inside a fake checkout holding the mocks.
    FAKE_SCRIPT_CHECKOUT_ROOT="$TMP/fake-script-checkout-root"
    TARGET_IC="$FAKE_SCRIPT_CHECKOUT_ROOT/$TARGET_IC_REL"
    mkdir -p "$TMP/mock-bin" "$FAKE_SCRIPT_CHECKOUT_ROOT/bin/github-issues" \
             "$FAKE_SCRIPT_CHECKOUT_ROOT/.github"
    touch "$FAKE_SCRIPT_CHECKOUT_ROOT/.github/labels.yml"

    # Default mock knobs
    : "${GH_MOCK_LABELS_HAVE_TASK:=1}"
    : "${GH_MOCK_SYNC_LABELS_FAIL:=0}"
    : "${GH_MOCK_CREATE_ISSUE_FAIL:=0}"

    # Create mock issue-create-preflight.sh — logs its invocation so tests can
    # assert POSITIVE evidence that Phase 0a actually ran the preflight.
    cat > "$FAKE_SCRIPT_CHECKOUT_ROOT/bin/github-issues/issue-create-preflight.sh" <<'PREFLIGHT_EOF'
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
    chmod +x "$FAKE_SCRIPT_CHECKOUT_ROOT/bin/github-issues/issue-create-preflight.sh"

    # Create mock sync-labels.sh
    cat > "$FAKE_SCRIPT_CHECKOUT_ROOT/bin/github-issues/sync-labels.sh" <<'SYNC_EOF'
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
    chmod +x "$FAKE_SCRIPT_CHECKOUT_ROOT/bin/github-issues/sync-labels.sh"
    # Copy the real tree around the two mocks (existing files are never overwritten).
    script_checkout_fixture_copy "$FAKE_SCRIPT_CHECKOUT_ROOT" bin hooks

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
# Placeholder — is-github-dotcom-remote is at <script checkout>/bin/is-github-dotcom-remote
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
    export WORKFLOW_STATE_DIR="$TMP/workflow"
    # gh_outbound_guard (sourced by issue-create.sh before the real gh call)
    # runs the scanner copied into the fake checkout, which reads its allow/block
    # lists from $AGENTS_MAIN_ROOT and fails CLOSED when the blocklist is missing.
    # Empty lists let it scan the clean placeholder title/body and return rc=0.
    export AGENTS_MAIN_ROOT="$TMP/fake-main-root"
    mkdir -p "$AGENTS_MAIN_ROOT"
    : > "$AGENTS_MAIN_ROOT/.private-info-allowlist"
    : > "$AGENTS_MAIN_ROOT/.private-info-blocklist"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    export WORKFLOW_STATE_DIR="$_PHASE0A_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_PHASE0A_TMP_ROOT/plans"
    unset MOCK_LOG AGENTS_MAIN_ROOT \
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
# TICA-4: no root env var at all → Phase 0a still RUNS. issue-create.sh finds the
# preflight and sync-labels beside its own path, so an absent AGENTS_MAIN_ROOT (and
# every retired root name) must not skip the label repair. Asserted on the calls:
# preflight ran, sync-labels ran, gh issue create ran, and no skip warning.
# The scanner then anchors its allow/block lists at the script checkout, so the
# empty lists are placed there for this case.
# ===========================================================================
setup_mock
export GH_MOCK_LABELS_HAVE_TASK=0
: > "$FAKE_SCRIPT_CHECKOUT_ROOT/.private-info-allowlist"
: > "$FAKE_SCRIPT_CHECKOUT_ROOT/.private-info-blocklist"
TICA4_UNSET=(-u AGENTS_MAIN_ROOT)
while IFS= read -r TICA4_NAME; do
    TICA4_NAME="${TICA4_NAME%$'\r'}"
    [ -n "$TICA4_NAME" ] && TICA4_UNSET+=(-u "$TICA4_NAME")
done < <(node "$__LIB_SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy-build.js" --print-retired-env-names 2>/dev/null)

STDERR_FILE="$TMP/tica4-stderr.log"
RC=0
OUT=$(env "${TICA4_UNSET[@]}" ISSUE_CREATE_SKIP_SCHEMA=1 bash "$TARGET_IC" \
    --title "Test issue" \
    --body "$VALID_BODY" \
    2>"$STDERR_FILE") || RC=$?

STDERR_CONTENT=$(cat "$STDERR_FILE" 2>/dev/null)
ISSUE_CREATE_CALLED=0
grep -q "issue create" "$MOCK_LOG" 2>/dev/null && ISSUE_CREATE_CALLED=1
SYNC_LABELS_CALLED=0
grep -q "sync-labels called" "$MOCK_LOG" 2>/dev/null && SYNC_LABELS_CALLED=1
PREFLIGHT_CALLED=0
preflight_invoked && PREFLIGHT_CALLED=1
SKIP_WARNED=0
echo "$STDERR_CONTENT" | grep -qiE "skipping label" && SKIP_WARNED=1

if [ "${#TICA4_UNSET[@]}" -gt 2 ] && [ "$RC" = "0" ] && [ "$PREFLIGHT_CALLED" = "1" ] \
   && [ "$SYNC_LABELS_CALLED" = "1" ] && [ "$ISSUE_CREATE_CALLED" = "1" ] && [ "$SKIP_WARNED" = "0" ]; then
    pass "TICA-4: no root env var → preflight ran → sync-labels ran → issue create proceeds, no skip warning"
else
    fail "TICA-4: rc=$RC unset-args=${#TICA4_UNSET[@]} preflight=$PREFLIGHT_CALLED sync=$SYNC_LABELS_CALLED create=$ISSUE_CREATE_CALLED skip-warned=$SKIP_WARNED stderr=$STDERR_CONTENT"
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
