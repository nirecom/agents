#!/bin/bash
# Tests: bin/github-issues/migration/migrate-history.sh, bin/github-issues/migration/preview-history.sh, bin/github-issues/migration/state.sh
# Tags: migration, repo, history, docs, github
# Tests for feat/migrate-repo — --history-files flag on migrate-history.sh and preview-history.sh.
#
# The flag allows callers to bypass auto-discovery and specify history archive files
# in an explicit order (relative to REPO_DIR). This is important when alphabetical
# sort order does not match chronological order.
#
# RED: fails clean while --history-files is not yet implemented.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIST_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/migrate-history.sh"
PREVIEW_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/preview-history.sh"
STATE_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/state.sh"
FIXTURE_DIR="$AGENTS_DIR/tests/fixtures/migration"

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
[ -f "$HIST_SCRIPT" ]    || missing+=("bin/github-issues/migration/migrate-history.sh")
[ -f "$PREVIEW_SCRIPT" ] || missing+=("bin/github-issues/migration/preview-history.sh")
[ -f "$STATE_SCRIPT" ]   || missing+=("bin/github-issues/migration/state.sh")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Fixture builder: creates a temp repo with two archive files whose
# alphabetical order is the REVERSE of the desired chronological order.
#   docs/history/aa-modern.md  — 1 entry: "Modern entry A"
#   docs/history/zz-legacy.md  — 2 entries: "Legacy entry 1", "Legacy entry 2"
# Alphabetical: aa-modern first (WRONG for chronology).
# Declared order via --history-files: zz-legacy,aa-modern (CORRECT).
# ---------------------------------------------------------------------------
build_fixture() {
    local base="$1"
    local repo="$base/repo"
    mkdir -p "$repo/docs/history"

    cat > "$repo/docs/history/zz-legacy.md" <<'EOF'
### Legacy entry 1 (2020-01-01)
Background: oldest entry
Changes: legacy change 1

### Legacy entry 2 (2020-06-01)
Background: second oldest
Changes: legacy change 2
EOF

    cat > "$repo/docs/history/aa-modern.md" <<'EOF'
### Modern entry A (2024-01-01)
Background: most recent
Changes: modern change
EOF

    # gh mock
    local mock_dir="$base/mock"
    mkdir -p "$mock_dir"
    cp "$FIXTURE_DIR/gh-mock.sh" "$mock_dir/gh"
    chmod +x "$mock_dir/gh"

    echo "$repo"
}

count_create_calls() {
    local log="$1"
    local n
    n=$(grep -c '^gh issue create' "$log" 2>/dev/null) || n=0
    echo "$n"
}

# ---------------------------------------------------------------------------
# HF1: Without --history-files, alphabetical sort → aa-modern processed first.
# ---------------------------------------------------------------------------
TMP_HF1="$(mktemp -d)"
REPO_HF1="$(build_fixture "$TMP_HF1")"
export MOCK_LOG="$TMP_HF1/mock.log"
export MOCK_COUNTER="$TMP_HF1/counter"
echo 101 > "$MOCK_COUNTER"
: > "$MOCK_LOG"
export PATH="$TMP_HF1/mock:$PATH"
export AGENTS_CONFIG_DIR="$AGENTS_DIR"

# shellcheck disable=SC1090
source "$STATE_SCRIPT"
state_init "$REPO_HF1" >/dev/null 2>&1
state_load "$REPO_HF1" >/dev/null 2>&1

run_with_timeout 30 bash "$HIST_SCRIPT" "$REPO_HF1" >/dev/null 2>&1

# Alphabetical: aa-modern.md is processed first → "Modern entry A" is first in log.
FIRST_LINE_HF1=$(grep '^gh issue create' "$MOCK_LOG" 2>/dev/null | head -1)
if echo "$FIRST_LINE_HF1" | grep -q "Modern entry A"; then
    pass "HF1: without --history-files alphabetical order → Modern entry A first"
else
    fail "HF1: expected 'Modern entry A' first in log, got: $FIRST_LINE_HF1"
fi
rm -rf "$TMP_HF1"

# ---------------------------------------------------------------------------
# HF2: With --history-files zz-legacy.md,aa-modern.md → "Legacy entry 1" first,
#      3 issues created total.
# ---------------------------------------------------------------------------
TMP_HF2="$(mktemp -d)"
REPO_HF2="$(build_fixture "$TMP_HF2")"
export MOCK_LOG="$TMP_HF2/mock.log"
export MOCK_COUNTER="$TMP_HF2/counter"
echo 101 > "$MOCK_COUNTER"
: > "$MOCK_LOG"
export PATH="$TMP_HF2/mock:$PATH"

source "$STATE_SCRIPT"
state_init "$REPO_HF2" >/dev/null 2>&1
state_load "$REPO_HF2" >/dev/null 2>&1

run_with_timeout 30 bash "$HIST_SCRIPT" "$REPO_HF2" \
    --history-files "zz-legacy.md,aa-modern.md" >/dev/null 2>&1

state_load "$REPO_HF2" >/dev/null 2>&1
TOTAL_HF2=$(state_count_migrated history 2>/dev/null)
FIRST_LINE_HF2=$(grep '^gh issue create' "$TMP_HF2/mock.log" 2>/dev/null | head -1)

if echo "$FIRST_LINE_HF2" | grep -q "Legacy entry 1" && [ "$TOTAL_HF2" = "3" ]; then
    pass "HF2: --history-files declared order → Legacy entry 1 first, 3 issues total"
else
    fail "HF2: first_line='$FIRST_LINE_HF2' total=$TOTAL_HF2 (expected Legacy entry 1 first, 3 total)"
fi
rm -rf "$TMP_HF2"

# ---------------------------------------------------------------------------
# HF3: Idempotency — fresh repo, run with --history-files (expect 3 created),
#      clear log, run again → 0 new gh issue create calls.
#      In RED phase: the first run creates 0 (flag unrecognized), so state has
#      0 migrated; re-run also creates 0. The test asserts BOTH that the first
#      run created 3 AND that the second run created 0, so it fails correctly.
# ---------------------------------------------------------------------------
TMP_HF3="$(mktemp -d)"
REPO_HF3="$(build_fixture "$TMP_HF3")"
export MOCK_LOG="$TMP_HF3/mock.log"
export MOCK_COUNTER="$TMP_HF3/counter"
echo 101 > "$MOCK_COUNTER"
: > "$MOCK_LOG"
export PATH="$TMP_HF3/mock:$PATH"

source "$STATE_SCRIPT"
state_init "$REPO_HF3" >/dev/null 2>&1
state_load "$REPO_HF3" >/dev/null 2>&1

# First run: should create 3 issues.
run_with_timeout 30 bash "$HIST_SCRIPT" "$REPO_HF3" \
    --history-files "zz-legacy.md,aa-modern.md" >/dev/null 2>&1

state_load "$REPO_HF3" >/dev/null 2>&1
AFTER_FIRST_RUN=$(state_count_migrated history 2>/dev/null || echo 0)

# Second run: clear log, run again, check 0 new calls.
: > "$TMP_HF3/mock.log"
run_with_timeout 30 bash "$HIST_SCRIPT" "$REPO_HF3" \
    --history-files "zz-legacy.md,aa-modern.md" >/dev/null 2>&1

NEW_CALLS_HF3=$(count_create_calls "$TMP_HF3/mock.log")

if [ "$AFTER_FIRST_RUN" = "3" ] && [ "$NEW_CALLS_HF3" = "0" ]; then
    pass "HF3: --history-files idempotency → first run=3, second run=0 new calls"
else
    fail "HF3: after_first_run=$AFTER_FIRST_RUN new_calls=$NEW_CALLS_HF3 (expected 3 then 0)"
fi
rm -rf "$TMP_HF3"

# ---------------------------------------------------------------------------
# HF4: --history-files with a non-existent file → exit non-zero AND
#      the flag must be recognized (not just "unknown arg").
#      We check that the error output mentions the filename, which only
#      happens when the feature is implemented.
# ---------------------------------------------------------------------------
TMP_HF4="$(mktemp -d)"
REPO_HF4="$(build_fixture "$TMP_HF4")"
export MOCK_LOG="$TMP_HF4/mock.log"
export MOCK_COUNTER="$TMP_HF4/counter"
echo 101 > "$MOCK_COUNTER"
: > "$MOCK_LOG"
export PATH="$TMP_HF4/mock:$PATH"

source "$STATE_SCRIPT"
state_init "$REPO_HF4" >/dev/null 2>&1
state_load "$REPO_HF4" >/dev/null 2>&1

ERR_HF4=$(run_with_timeout 30 bash "$HIST_SCRIPT" "$REPO_HF4" \
    --history-files "nonexistent-file.md" 2>&1)
RC_HF4=$?

# Must exit non-zero AND the error must reference the missing filename
# (not just "unknown arg" from unimplemented flag handling).
if [ "$RC_HF4" -ne 0 ] && echo "$ERR_HF4" | grep -q "nonexistent-file.md"; then
    pass "HF4: --history-files with non-existent file → exit non-zero with filename in error"
else
    fail "HF4: rc=$RC_HF4 err='$ERR_HF4' (expected non-zero and filename in error message)"
fi
rm -rf "$TMP_HF4"

# ---------------------------------------------------------------------------
# HF5: preview-history.sh --history-files zz-legacy.md,aa-modern.md outputs
#      entries in declared order: Legacy entries listed before Modern entries.
# ---------------------------------------------------------------------------
TMP_HF5="$(mktemp -d)"
REPO_HF5="$(build_fixture "$TMP_HF5")"
export MOCK_LOG="$TMP_HF5/mock.log"
export MOCK_COUNTER="$TMP_HF5/counter"
echo 101 > "$MOCK_COUNTER"
: > "$MOCK_LOG"
export PATH="$TMP_HF5/mock:$PATH"

PREVIEW_OUT=$(run_with_timeout 30 bash "$PREVIEW_SCRIPT" "$REPO_HF5" \
    --history-files "zz-legacy.md,aa-modern.md" 2>&1)

# Check that "Legacy entry 1" appears before "Modern entry A" in the output.
LEGACY_POS=$(echo "$PREVIEW_OUT" | grep -n "Legacy entry 1" | head -1 | cut -d: -f1)
MODERN_POS=$(echo "$PREVIEW_OUT" | grep -n "Modern entry A" | head -1 | cut -d: -f1)

if [ -n "$LEGACY_POS" ] && [ -n "$MODERN_POS" ] && [ "$LEGACY_POS" -lt "$MODERN_POS" ]; then
    pass "HF5: preview-history.sh --history-files declared order → Legacy before Modern"
else
    fail "HF5: legacy_pos=${LEGACY_POS:-missing} modern_pos=${MODERN_POS:-missing} (expected legacy < modern)"
fi
rm -rf "$TMP_HF5"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
