#!/bin/bash
# Test suite for install-obsolete workflow migration cleanup logic
# Tests the _salvage_git_workflow / run_migration functions

ERRORS=0
TMPDIR_BASE=""

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# ---- timeout wrapper (macOS-compatible) ----
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# ---- cleanup on exit ----
cleanup() {
    [ -n "$TMPDIR_BASE" ] && rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

# ---- create isolated temp environment ----
setup() {
    TMPDIR_BASE="$(mktemp -d)"
    export TEST_WF_NEW_DIR="$TMPDIR_BASE/new"
    export TEST_WF_SEARCH_ROOT="$TMPDIR_BASE/search"
    mkdir -p "$TEST_WF_SEARCH_ROOT"
}

reset_dirs() {
    rm -rf "$TMPDIR_BASE/new" "$TEST_WF_SEARCH_ROOT"
    mkdir -p "$TEST_WF_SEARCH_ROOT"
}

# ---- logic under test (embedded) ----
_wf_new_dir="${TEST_WF_NEW_DIR:-$HOME/.claude/projects/workflow}"
_wf_search_root="${TEST_WF_SEARCH_ROOT:-$HOME}"

_salvage_git_workflow() {
    local old="$1"
    [ -d "$old" ] || return
    local n=0
    for f in "$old"/*.json; do
        [ -f "$f" ] || continue
        if find "$f" -mtime -7 2>/dev/null | grep -q .; then
            mkdir -p "$_wf_new_dir"
            cp "$f" "$_wf_new_dir/"
            n=$((n+1))
        fi
    done
    rm -rf "$old"
}

run_migration() {
    while IFS= read -r -d '' d; do
        _salvage_git_workflow "$d"
    done < <(find "$_wf_search_root" -maxdepth 4 -name "workflow" -path "*/.git/workflow" -type d -print0 2>/dev/null)
}

# Re-bind after setup() sets the env vars
rebind_vars() {
    _wf_new_dir="$TEST_WF_NEW_DIR"
    _wf_search_root="$TEST_WF_SEARCH_ROOT"
}

# ---- helpers ----
make_old_dir() {
    # make_old_dir <repo_name> → creates <search>/<repo>/.git/workflow/
    local repo="$1"
    local d="$TEST_WF_SEARCH_ROOT/$repo/.git/workflow"
    mkdir -p "$d"
    echo "$d"
}

make_recent_json() {
    # make_recent_json <path> <filename>
    local dir="$1" name="$2"
    touch "$dir/$name"
}

make_old_json() {
    # make_old_json <path> <filename> — 8 days old
    local dir="$1" name="$2"
    touch -d "8 days ago" "$dir/$name"
}

make_boundary_json() {
    # make_boundary_json <path> <filename> — 169h old (just over 7*24h)
    # find -mtime -7 is strictly less than 7*24h → 169h is NOT salvaged
    # Note: "touch -d '7 days ago'" sets exactly 168h which may still match
    # on some platforms; 169 hours reliably exceeds the threshold.
    local dir="$1" name="$2"
    touch -d "169 hours ago" "$dir/$name"
}

# ============================================================
# T1: recent files only → all salvaged, old dir removed
# ============================================================
test_recent_files_salvaged() {
    reset_dirs; rebind_vars
    local d; d=$(make_old_dir "repo1")
    make_recent_json "$d" "state.json"
    make_recent_json "$d" "session.json"

    run_migration

    local ok=1
    [ -f "$TEST_WF_NEW_DIR/state.json" ]   || { ok=0; }
    [ -f "$TEST_WF_NEW_DIR/session.json" ] || { ok=0; }
    [ ! -d "$d" ]                           || { ok=0; }

    [ "$ok" -eq 1 ] && pass "T1: recent files salvaged, old dir removed" \
                     || fail "T1: recent files salvaged, old dir removed"
}

# ============================================================
# T2: mixed (recent + old) → only recent salvaged, old dir removed
# ============================================================
test_mixed_files() {
    reset_dirs; rebind_vars
    local d; d=$(make_old_dir "repo2")
    make_recent_json "$d" "new.json"
    make_old_json    "$d" "old.json"

    run_migration

    local ok=1
    [ -f "$TEST_WF_NEW_DIR/new.json" ] || { ok=0; }
    [ ! -f "$TEST_WF_NEW_DIR/old.json" ] || { ok=0; }
    [ ! -d "$d" ] || { ok=0; }

    [ "$ok" -eq 1 ] && pass "T2: mixed files — only recent salvaged, old dir removed" \
                     || fail "T2: mixed files — only recent salvaged, old dir removed"
}

# ============================================================
# T3: multiple repos → all processed
# ============================================================
test_multiple_repos() {
    reset_dirs; rebind_vars
    local d1; d1=$(make_old_dir "repoA")
    local d2; d2=$(make_old_dir "repoB")
    make_recent_json "$d1" "a.json"
    make_recent_json "$d2" "b.json"

    run_migration

    local ok=1
    [ -f "$TEST_WF_NEW_DIR/a.json" ] || { ok=0; }
    [ -f "$TEST_WF_NEW_DIR/b.json" ] || { ok=0; }
    [ ! -d "$d1" ] || { ok=0; }
    [ ! -d "$d2" ] || { ok=0; }

    [ "$ok" -eq 1 ] && pass "T3: multiple repos all processed" \
                     || fail "T3: multiple repos all processed"
}

# ============================================================
# T4: .git/workflow absent → no-op, no error
# ============================================================
test_absent_dir() {
    reset_dirs; rebind_vars
    # no .git/workflow dirs created

    run_migration
    local rc=$?

    local ok=1
    [ $rc -eq 0 ] || { ok=0; }
    [ ! -d "$TEST_WF_NEW_DIR" ] || { ok=0; }  # nothing created

    [ "$ok" -eq 1 ] && pass "T4: absent dir is a no-op" \
                     || fail "T4: absent dir is a no-op"
}

# ============================================================
# T5: empty .git/workflow dir → just deleted
# ============================================================
test_empty_dir() {
    reset_dirs; rebind_vars
    local d; d=$(make_old_dir "repo_empty")

    run_migration

    local ok=1
    [ ! -d "$d" ] || { ok=0; }
    [ ! -d "$TEST_WF_NEW_DIR" ] || { ok=0; }  # no dest created when nothing salvaged

    [ "$ok" -eq 1 ] && pass "T5: empty dir deleted, no dest created" \
                     || fail "T5: empty dir deleted, no dest created"
}

# ============================================================
# T6: old files only (>7 days) → no salvage, old dir removed
# ============================================================
test_old_files_only() {
    reset_dirs; rebind_vars
    local d; d=$(make_old_dir "repo_old")
    make_old_json "$d" "stale.json"

    run_migration

    local ok=1
    [ ! -d "$d" ] || { ok=0; }
    [ ! -f "$TEST_WF_NEW_DIR/stale.json" ] || { ok=0; }

    [ "$ok" -eq 1 ] && pass "T6: old files not salvaged, old dir removed" \
                     || fail "T6: old files not salvaged, old dir removed"
}

# ============================================================
# T7: boundary value (exactly 7 days → NOT salvaged by find -mtime -7)
# ============================================================
test_boundary_7days() {
    reset_dirs; rebind_vars
    local d; d=$(make_old_dir "repo_boundary")
    make_boundary_json "$d" "boundary.json"

    run_migration

    local ok=1
    [ ! -d "$d" ] || { ok=0; }
    [ ! -f "$TEST_WF_NEW_DIR/boundary.json" ] || { ok=0; }

    [ "$ok" -eq 1 ] && pass "T7: exactly-7-day file NOT salvaged (boundary)" \
                     || fail "T7: exactly-7-day file NOT salvaged (boundary)"
}

# ============================================================
# T8: dest already has same file → overwrite, no error
# ============================================================
test_overwrite_existing() {
    reset_dirs; rebind_vars
    local d; d=$(make_old_dir "repo_overwrite")
    make_recent_json "$d" "conflict.json"
    echo "old content" > "$d/conflict.json"

    mkdir -p "$TEST_WF_NEW_DIR"
    echo "existing content" > "$TEST_WF_NEW_DIR/conflict.json"

    run_migration

    local ok=1
    [ ! -d "$d" ] || { ok=0; }
    [ -f "$TEST_WF_NEW_DIR/conflict.json" ] || { ok=0; }
    # Should have overwritten — content from old dir (not "existing content")
    grep -q "old content" "$TEST_WF_NEW_DIR/conflict.json" 2>/dev/null || { ok=0; }

    [ "$ok" -eq 1 ] && pass "T8: overwrite existing dest file, no error" \
                     || fail "T8: overwrite existing dest file, no error"
}

# ============================================================
# T9: idempotency — run twice, second run is no-op
# ============================================================
test_idempotency() {
    reset_dirs; rebind_vars
    local d; d=$(make_old_dir "repo_idem")
    make_recent_json "$d" "idem.json"

    run_migration  # first run

    # second run: old dir gone, nothing to find
    run_migration
    local rc=$?

    local ok=1
    [ $rc -eq 0 ] || { ok=0; }
    [ -f "$TEST_WF_NEW_DIR/idem.json" ] || { ok=0; }  # still present from first run
    [ ! -d "$d" ] || { ok=0; }

    [ "$ok" -eq 1 ] && pass "T9: idempotency — second run is no-op" \
                     || fail "T9: idempotency — second run is no-op"
}

# ============================================================
# main
# ============================================================
setup

run_with_timeout bash -c "
    source '$(realpath "$0")' --source-only 2>/dev/null || true
" 2>/dev/null || true

# Run tests directly (functions are already defined in this script)
test_recent_files_salvaged
test_mixed_files
test_multiple_repos
test_absent_dir
test_empty_dir
test_old_files_only
test_boundary_7days
test_overwrite_existing
test_idempotency

echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
