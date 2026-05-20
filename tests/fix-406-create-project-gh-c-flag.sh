#!/bin/bash
# Tests for fix #406 — create-project.sh must NOT use `gh -C` (git flag, not gh flag).
# Fixed form: (cd "$REPO_DIR" && gh repo view ...) instead of gh -C "$REPO_DIR" repo view ...
#
# Test cases:
#   C1  — Non-dry-run exits 0 with mock gh in PATH
#   C1b — State file has correct .project schema after C1
#   C2  — Mock log shows `gh repo view` (positive) and NOT `gh -C` (negative — FAILS before fix)
#   C3  — Dry-run exits 0 and mock log has NO `gh repo view`
#   C4  — Existing-project path: no createProjectV2 call when project already exists

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/create-project.sh"
GH_MOCK="$AGENTS_DIR/tests/fixtures/migration/gh-mock.sh"
STATE_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/state.sh"

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

# --- Existence gate -----------------------------------------------------------
missing=()
[ -f "$CREATE_SCRIPT" ] || missing+=("bin/github-issues/migration/create-project.sh")
[ -f "$GH_MOCK" ]       || missing+=("tests/fixtures/migration/gh-mock.sh")
[ -f "$STATE_SCRIPT" ]  || missing+=("bin/github-issues/migration/state.sh")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

# --- Shared fixture helpers ---------------------------------------------------
TMPROOT=""
REPO=""

setup_fixture() {
    local has_existing_project="${1:-0}"
    TMPROOT="$(mktemp -d)"
    REPO="$TMPROOT/repo"

    # Minimal repo dir with initialized state file.
    mkdir -p "$REPO"
    # shellcheck disable=SC1090
    source "$STATE_SCRIPT"
    state_init "$REPO" >/dev/null 2>&1

    # gh shim pointing to gh-mock.sh.
    mkdir -p "$TMPROOT/bin"
    printf '#!/bin/bash\nexec "%s" "$@"\n' "$GH_MOCK" > "$TMPROOT/bin/gh"
    chmod +x "$TMPROOT/bin/gh"

    export PATH="$TMPROOT/bin:$PATH"
    export MOCK_LOG="$TMPROOT/gh-mock.log"
    export MOCK_COUNTER="$TMPROOT/gh-mock-counter"
    : > "$MOCK_LOG"

    if [ "$has_existing_project" = "1" ]; then
        export MOCK_HAS_EXISTING_PROJECT="1"
    else
        unset MOCK_HAS_EXISTING_PROJECT 2>/dev/null || true
    fi
}

teardown_fixture() {
    if [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ]; then
        rm -rf "$TMPROOT"
    fi
    unset MOCK_LOG MOCK_COUNTER MOCK_HAS_EXISTING_PROJECT 2>/dev/null || true
    TMPROOT=""
    REPO=""
}

# =============================================================================
# C1 — Non-dry-run exits 0
# =============================================================================
setup_fixture 0
C1_LOG="$MOCK_LOG"
C1_REPO="$REPO"

OUT=$(run_with_timeout 30 bash "$CREATE_SCRIPT" "$REPO" 2>&1)
RC=$?
C1_OUT="$OUT"

if [ "$RC" -eq 0 ]; then
    pass "C1: create-project.sh exits 0 (non-dry-run)"
else
    fail "C1: rc=$RC output=$OUT"
fi

C1_STATE="$REPO/.migration-state.json"

# =============================================================================
# C1b — State file has correct .project schema
# =============================================================================
if [ ! -f "$C1_STATE" ]; then
    fail "C1b: .migration-state.json not found after run"
else
    proj_num=$(jq -r '.project.number' "$C1_STATE" 2>/dev/null)
    proj_nid=$(jq -r '.project.node_id' "$C1_STATE" 2>/dev/null)
    field_id=$(jq -r '.project.field_ids["Content Date"]' "$C1_STATE" 2>/dev/null)

    ok=1
    [ "$proj_num" = "99" ]                    || { echo "  C1b: project.number expected 99, got '$proj_num'"; ok=0; }
    [ "$proj_nid" = "PVT_kwDOmock" ]          || { echo "  C1b: project.node_id expected PVT_kwDOmock, got '$proj_nid'"; ok=0; }
    [ "$field_id" = "PVTF_contentdate_mock" ] || { echo "  C1b: field_ids[Content Date] expected PVTF_contentdate_mock, got '$field_id'"; ok=0; }

    if [ "$ok" = "1" ]; then
        pass "C1b: .project.number=99, .project.node_id=PVT_kwDOmock, field_ids[Content Date]=PVTF_contentdate_mock"
    else
        fail "C1b: state schema mismatch (see above). State: $(cat "$C1_STATE" 2>/dev/null)"
    fi
fi

# =============================================================================
# C2 — Mock log: `gh repo view` present (positive); `gh -C` absent (negative)
#      NOTE: C2 negative assertion FAILS before the source fix is applied.
# =============================================================================
C2_LOG="$C1_LOG"

if grep -qE '^gh repo view' "$C2_LOG" 2>/dev/null; then
    pass "C2a: mock log contains 'gh repo view' invocation"
else
    fail "C2a: mock log missing 'gh repo view'. Log: $(cat "$C2_LOG" 2>/dev/null | head -10)"
fi

if grep -qE '^gh -C' "$C2_LOG" 2>/dev/null; then
    fail "C2b: mock log contains 'gh -C' (bug not fixed — lines 32-33 still use wrong flag). Log: $(grep '^gh -C' "$C2_LOG")"
else
    pass "C2b: mock log does NOT contain 'gh -C' (fix confirmed)"
fi

teardown_fixture

# =============================================================================
# C3 — Dry-run: exits 0, no `gh repo view` in log
# =============================================================================
setup_fixture 0
C3_LOG="$MOCK_LOG"

OUT=$(run_with_timeout 30 bash "$CREATE_SCRIPT" "$REPO" --dry-run 2>&1)
RC=$?

if [ "$RC" -eq 0 ]; then
    pass "C3: create-project.sh --dry-run exits 0"
else
    fail "C3: --dry-run rc=$RC output=$OUT"
fi

if grep -qE '^gh repo view' "$C3_LOG" 2>/dev/null; then
    fail "C3b: dry-run invoked 'gh repo view' (should have exited early)"
else
    pass "C3b: dry-run did NOT invoke 'gh repo view'"
fi

teardown_fixture

# =============================================================================
# C4 — Existing-project path: no createProjectV2 mutation called
# =============================================================================
setup_fixture 1
C4_LOG="$MOCK_LOG"

OUT=$(run_with_timeout 30 bash "$CREATE_SCRIPT" "$REPO" 2>&1)
RC=$?

if [ "$RC" -eq 0 ]; then
    pass "C4: create-project.sh exits 0 with existing project"
else
    fail "C4: rc=$RC output=$OUT"
fi

if grep -qE 'createProjectV2\b' "$C4_LOG" 2>/dev/null; then
    fail "C4b: createProjectV2 mutation was called on existing-project path. Log: $(grep 'createProjectV2' "$C4_LOG")"
else
    pass "C4b: no createProjectV2 mutation on existing-project path"
fi

teardown_fixture

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
