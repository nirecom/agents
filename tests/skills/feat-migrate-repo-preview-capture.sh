#!/bin/bash
# tests/skills/feat-migrate-repo-preview-capture.sh
# Tests: skills/migrate-repo/scripts/preview-and-capture.sh
# Tags: migration, repo, preview, identity-guard, scope:issue-specific
#
# L3 gap (what this test does NOT catch): real gh / real GitHub self-repo
# issue enumeration, and the captured snapshot flowing into a live
# orchestrate.sh run; checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: installer.
# PF-PC1 (#1234): the repo path equals the checkout the script itself lives in
# (the self-repo condition); the identity guard's dry-run signals must appear.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREVIEW_REL="skills/migrate-repo/scripts/preview-and-capture.sh"
PREVIEW_SCRIPT="$SCRIPT_CHECKOUT_ROOT/$PREVIEW_REL"
ORCH_SCRIPT="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/migration/orchestrate.sh"
FIXTURE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/fixtures/migration"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# --- Existence gate ---------------------------------------------------------
missing=()
[ -f "$PREVIEW_SCRIPT" ] || missing+=("skills/migrate-repo/scripts/preview-and-capture.sh")
[ -f "$ORCH_SCRIPT" ] || missing+=("bin/github-issues/migration/orchestrate.sh")
[ -f "$FIXTURE_DIR/gh-mock.sh" ] || missing+=("tests/fixtures/migration/gh-mock.sh")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Fixture: gh-mock on PATH + AGENTS_MAIN_ROOT set (overridden per case for self-repo).
# ---------------------------------------------------------------------------
setup_fixture() {
    TMP="$(mktemp -d)"

    MOCK_DIR="$TMP/mock"
    mkdir -p "$MOCK_DIR"
    cp "$FIXTURE_DIR/gh-mock.sh" "$MOCK_DIR/gh"
    chmod +x "$MOCK_DIR/gh"

    MOCK_LOG="$TMP/mock.log"
    MOCK_COUNTER="$TMP/counter"
    echo 101 > "$MOCK_COUNTER"
    : > "$MOCK_LOG"

    export MOCK_LOG MOCK_COUNTER
    export PATH="$MOCK_DIR:$PATH"
}

teardown_fixture() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset MOCK_LOG MOCK_COUNTER AGENTS_MAIN_ROOT MOCK_HAS_ISSUES
}

# ---------------------------------------------------------------------------
# PF-PC1: preview-and-capture.sh against a self-repo.
#         Capture stdout and stderr to separate files. Four sub-assertions:
#         (a) rc==0
#         (b) stdout contains "MIGRATE_SELF_REPO_DETECTED=1"
#         (c) stdout contains BOTH "MIGRATE_DRY_RUN_HIGHEST_ISSUE_N"
#             and "MIGRATE_DRY_RUN_SELF_COUNT"
#         (d) stderr contains "SELF_REPO_DETECTED"
#         FAIL-BEFORE-FIX: identity guard absent → (b) and (d) fail.
# ---------------------------------------------------------------------------
setup_fixture
unset MOCK_HAS_ISSUES
SELF_PC1="$TMP/selfrepo"
mkdir -p "$SELF_PC1/docs"
cat > "$SELF_PC1/docs/history.md" <<'EOF'
### Entry 1 (2024-01-01)
Background: test entry 1
Changes: change 1
EOF
# Both preview-and-capture.sh and orchestrate.sh compare the repo path with the
# checkout they live in, so the self-repo condition needs a real copy of both
# (and of orchestrate.sh's siblings) inside the repo under test.
script_checkout_fixture_copy "$SELF_PC1" bin "${PREVIEW_REL%/*}" \
    || fail "PF-PC1: fixture copy failed"
SELF_PC1="$(cd "$SELF_PC1" && pwd)"

run_with_timeout 30 bash "$SELF_PC1/$PREVIEW_REL" "$SELF_PC1" > "$TMP/stdout" 2> "$TMP/stderr"
RC=$?

A=0; [ "$RC" -eq 0 ] && A=1
B=$(grep -c "MIGRATE_SELF_REPO_DETECTED=1" "$TMP/stdout" 2>/dev/null) || B=0
C1=$(grep -c "MIGRATE_DRY_RUN_HIGHEST_ISSUE_N" "$TMP/stdout" 2>/dev/null) || C1=0
C2=$(grep -c "MIGRATE_DRY_RUN_SELF_COUNT" "$TMP/stdout" 2>/dev/null) || C2=0
D=$(grep -c "SELF_REPO_DETECTED" "$TMP/stderr" 2>/dev/null) || D=0

if [ "$A" -eq 1 ] && [ "$B" -gt 0 ] && [ "$C1" -gt 0 ] && [ "$C2" -gt 0 ] && [ "$D" -gt 0 ]; then
    pass "PF-PC1: preview-and-capture self-repo emits guard sentinels + stderr marker"
else
    fail "PF-PC1: rc=$RC(a=$A) self_sentinel=$B highest=$C1 selfcount=$C2 stderr_marker=$D (expected a=1, self_sentinel>0, highest>0, selfcount>0, stderr_marker>0)"
fi
teardown_fixture

# ---------------------------------------------------------------------------
# PF-PC2: preview-and-capture.sh against a NON-self repo (normal path).
#         The self-repo guard must NOT fire:
#         (a) rc == 0
#         (b) stdout contains "MIGRATE_SELF_REPO_DETECTED=0"
#         (c) stdout does NOT contain bare ^MIGRATE_DRY_RUN_HIGHEST_ISSUE_N= or
#             ^MIGRATE_DRY_RUN_SELF_COUNT= lines (these are self-repo-only)
#         (d) stderr does NOT contain "SELF_REPO_DETECTED"
#         (e) stdout contains "export MIGRATE_ACK_UP_TO_ISSUE_N="
# ---------------------------------------------------------------------------
setup_fixture
unset MOCK_HAS_ISSUES

# Build a minimal non-self fixture repo (distinct from AGENTS_MAIN_ROOT)
REPO_NORMAL="$TMP/repo"
mkdir -p "$REPO_NORMAL/docs"
cat > "$REPO_NORMAL/docs/history.md" <<'HISTEOF'
### Entry 1 (2024-01-01)
Background: test entry 1
Changes: change 1
HISTEOF

run_with_timeout 30 bash "$PREVIEW_SCRIPT" "$REPO_NORMAL" > "$TMP/stdout" 2> "$TMP/stderr"
RC=$?

A=0; [ "$RC" -eq 0 ] && A=1
B=$(grep -c "MIGRATE_SELF_REPO_DETECTED=0" "$TMP/stdout" 2>/dev/null) || B=0
C1=$(grep -c "^MIGRATE_DRY_RUN_HIGHEST_ISSUE_N=" "$TMP/stdout" 2>/dev/null) || C1=0
C2=$(grep -c "^MIGRATE_DRY_RUN_SELF_COUNT=" "$TMP/stdout" 2>/dev/null) || C2=0
D=$(grep -c "SELF_REPO_DETECTED" "$TMP/stderr" 2>/dev/null) || D=0
E=$(grep -c "export MIGRATE_ACK_UP_TO_ISSUE_N=" "$TMP/stdout" 2>/dev/null) || E=0

if [ "$A" -eq 1 ] && [ "$B" -gt 0 ] && [ "$C1" -eq 0 ] && [ "$C2" -eq 0 ] && [ "$D" -eq 0 ] && [ "$E" -gt 0 ]; then
    pass "PF-PC2: preview-and-capture normal path emits export sentinels, no guard firing"
else
    fail "PF-PC2: rc=$RC(a=$A) self_sentinel_0=$B dry_highest=$C1 dry_self=$C2 stderr_guard=$D export_ack=$E (expected a=1,B>0,C1=0,C2=0,D=0,E>0)"
fi
teardown_fixture

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
