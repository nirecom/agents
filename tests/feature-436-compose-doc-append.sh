#!/bin/bash
# tests/feature-436-compose-doc-append.sh
# Tests: bin/compose-doc-append-entry, hooks/lib/worktree-notes.js
# Tags: worktree, docs, append, history, compose
#
# Tests for bin/compose-doc-append-entry (issue #436).
# CLI reads WORKTREE_NOTES.md sections and appends entries to
# docs/history.md and CHANGELOG.md in separate commits from main worktree.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

PASS=0
FAIL=0
TEST_TMPS=()

cleanup_tmps() {
    for d in "${TEST_TMPS[@]}"; do
        [ -n "$d" ] && rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup_tmps EXIT

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# git rev-parse --git-common-dir returns relative ".git" for non-linked worktrees;
# resolve to absolute so ls/stat work from any CWD.
git_common_abs() {
    local repo="$1"
    local raw; raw="$(git -C "$repo" rev-parse --git-common-dir)"
    if [[ "$raw" = /* ]] || [[ "$raw" =~ ^[A-Za-z]: ]]; then
        echo "$raw"
    else
        echo "$repo/$raw"
    fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

CLI="$AGENTS_DIR/bin/compose-doc-append-entry"
if [ ! -f "$CLI" ]; then
    echo "SKIP: bin/compose-doc-append-entry not found (RED phase — not yet implemented)"
    echo ""
    echo "Results: 0 passed, 0 failed (skipped)"
    exit 0
fi

if ! command -v doc-append >/dev/null 2>&1; then
    echo "SKIP: doc-append not in PATH"
    echo ""
    echo "Results: 0 passed, 0 failed (skipped)"
    exit 0
fi

setup_test_repo() {
    local tmp; tmp=$(mktemp -d)
    TEST_TMPS+=("$tmp")
    local upstream="$tmp/upstream.git"
    local work="$tmp/work"
    git init --bare --initial-branch=main "$upstream" >/dev/null
    git init --initial-branch=main "$work" >/dev/null
    git -C "$work" config core.hooksPath /dev/null
    git -C "$work" config user.email "test@example.com"
    git -C "$work" config user.name "Test"
    (cd "$work"
        git remote add origin "$upstream"
        mkdir -p docs/history
        printf "# History\n" > docs/history.md
        printf "# Changelog\n" > CHANGELOG.md
        git add docs/history.md CHANGELOG.md
        git commit --no-verify -m "init" >/dev/null
        git push -u origin main >/dev/null 2>&1
        git remote set-head origin main >/dev/null 2>&1
    )
    echo "$work"
}

make_notes() {
    # Args: $1=history_content, $2=changelog_content
    local tmp; tmp=$(mktemp)
    TEST_TMPS+=("$tmp")
    cat > "$tmp" <<EOF
## History Notes
$1

## Changelog Notes
$2
EOF
    echo "$tmp"
}

run_cli() {
    # Run CLI with COMPOSE_DOC_APPEND_SKILL=1 in the given repo dir
    # Additional args: --notes, --branch, --pr, etc.
    local repo="$1"; shift
    (cd "$repo" && COMPOSE_DOC_APPEND_SKILL=1 run_with_timeout 30 bash "$CLI" "$@")
}

commit_count_since_init() {
    # Count commits after init (i.e., new commits produced by CLI)
    local repo="$1"
    git -C "$repo" rev-list HEAD ^"$(git -C "$repo" rev-list --max-parents=0 HEAD)" --count
}

# ============================================================================
# F-series — bin/compose-doc-append-entry CLI behavior
# ============================================================================

echo "--- F1: notes file missing ---"
_f1_repo="$(setup_test_repo)"
_f1_before="$(commit_count_since_init "$_f1_repo")"
run_cli "$_f1_repo" --notes "/nonexistent/WORKTREE_NOTES.md" --branch "feat/436" --pr "42"
_f1_exit=$?
_f1_after="$(commit_count_since_init "$_f1_repo")"
if [ "$_f1_exit" -eq 0 ] && [ "$_f1_after" -eq "$_f1_before" ]; then
    pass "F1: notes file missing → exit 0, no new commits"
else
    fail "F1: notes file missing → expected exit 0 and no commits (exit=$_f1_exit, commits_before=$_f1_before, after=$_f1_after)"
fi

echo "--- F2: both sections empty ---"
_f2_repo="$(setup_test_repo)"
_f2_notes="$(make_notes "- (none)" "- (none)")"
_f2_before="$(commit_count_since_init "$_f2_repo")"
run_cli "$_f2_repo" --notes "$_f2_notes" --branch "feat/436" --pr "42"
_f2_exit=$?
_f2_after="$(commit_count_since_init "$_f2_repo")"
if [ "$_f2_exit" -eq 0 ] && [ "$_f2_after" -eq "$_f2_before" ]; then
    pass "F2: both sections (none) → exit 0, no new commits"
else
    fail "F2: both sections (none) → expected exit 0 and no commits (exit=$_f2_exit, before=$_f2_before, after=$_f2_after)"
fi

echo "--- F9: --dry-run ---"
_f9_repo="$(setup_test_repo)"
_f9_notes="$(make_notes "- Dry run history" "- Dry run changelog")"
_f9_before="$(commit_count_since_init "$_f9_repo")"
_f9_git_common="$(git_common_abs "$_f9_repo")"
run_cli "$_f9_repo" --notes "$_f9_notes" --branch "feat/436" --pr "42" --dry-run
_f9_exit=$?
_f9_after="$(commit_count_since_init "$_f9_repo")"
_f9_marker_count="$(ls "$_f9_git_common/compose-doc-append-state" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$_f9_exit" -eq 0 ] && [ "$_f9_after" -eq "$_f9_before" ] && [ "$_f9_marker_count" -eq 0 ]; then
    pass "F9: --dry-run → no commits, no marker file"
else
    fail "F9: --dry-run (exit=$_f9_exit, before=$_f9_before, after=$_f9_after, markers=$_f9_marker_count)"
fi

echo "--- F10: push failure (TODO) ---"
echo "SKIP: F10 (push failure simulation deferred)"

echo "--- F11: no commits → no push ---"
# Already covered by F2; verify exit 0 explicitly
_f11_repo="$(setup_test_repo)"
_f11_notes="$(make_notes "- (none)" "- (none)")"
run_cli "$_f11_repo" --notes "$_f11_notes" --branch "feat/436" --pr "42"
_f11_exit=$?
if [ "$_f11_exit" -eq 0 ]; then
    pass "F11: no commits produced → exit 0, no push attempted"
else
    fail "F11: no commits case (exit=$_f11_exit)"
fi

echo "--- F15: --pr validation ---"
_f15_repo="$(setup_test_repo)"
_f15_notes="$(make_notes "- F15" "- (none)")"
run_cli "$_f15_repo" --notes "$_f15_notes" --branch "feat/436" --pr "abc"
_f15_exit=$?
if [ "$_f15_exit" -ne 0 ]; then
    pass "F15: --pr abc (non-digits) → exit non-zero (validation)"
else
    fail "F15: --pr abc should have exited non-zero but got exit 0"
fi

echo "--- F16: --branch validation ---"
_f16_repo="$(setup_test_repo)"
_f16_notes="$(make_notes "- F16" "- (none)")"
run_cli "$_f16_repo" --notes "$_f16_notes" --branch "feat;injected" --pr "42"
_f16_exit=$?
if [ "$_f16_exit" -ne 0 ]; then
    pass "F16: --branch with ';' → exit non-zero (validation)"
else
    fail "F16: --branch 'feat;injected' should have exited non-zero but got exit 0"
fi

echo "--- F17: heading case sensitivity ---"
_f17_repo="$(setup_test_repo)"
# Create notes with WRONG casing for heading
_f17_notes_tmp="$(mktemp)"
TEST_TMPS+=("$_f17_notes_tmp")
cat > "$_f17_notes_tmp" <<'NOTESEOF'
## history notes
- Should be ignored (wrong casing)

## changelog notes
- Should also be ignored (wrong casing)
NOTESEOF
_f17_before="$(commit_count_since_init "$_f17_repo")"
run_cli "$_f17_repo" --notes "$_f17_notes_tmp" --branch "feat/436" --pr "42"
_f17_exit=$?
_f17_after="$(commit_count_since_init "$_f17_repo")"
if [ "$_f17_exit" -eq 0 ] && [ "$_f17_after" -eq "$_f17_before" ]; then
    pass "F17: wrong-cased headings → sections not extracted, no commits"
else
    fail "F17: heading case (exit=$_f17_exit, before=$_f17_before, after=$_f17_after)"
fi

echo "--- F17b: buildNotesBody template ---"
_f17b_result="$(run_with_timeout 15 node -e "
    const m = require('$_AGENTS_DIR_NODE/hooks/lib/worktree-notes.js');
    const body = typeof m.buildNotesBody === 'function' ? m.buildNotesBody() : '';
    process.stdout.write(body);
" 2>/dev/null)"
if echo "$_f17b_result" | grep -q "## History Notes" && \
   echo "$_f17b_result" | grep -q "## Changelog Notes"; then
    pass "F17b: buildNotesBody contains '## History Notes' and '## Changelog Notes'"
else
    fail "F17b: buildNotesBody missing expected headings (has_history=$(echo "$_f17b_result" | grep -c "## History Notes"), has_changelog=$(echo "$_f17b_result" | grep -c "## Changelog Notes"))"
fi

echo "--- F22: CLOSES_ISSUES_COUNT=1 + History Notes has only placeholder → exit non-zero ---"
_f22_repo="$(setup_test_repo)"
_f22_notes="$(make_notes "- (none)" "- (none)")"
run_cli "$_f22_repo" --notes "$_f22_notes" --branch "feat/436" --pr "42" --closes-issues-count 1
_f22_exit=$?
if [ "$_f22_exit" -ne 0 ]; then
    pass "F22: --closes-issues-count 1 + placeholder History → exit non-zero"
else
    fail "F22: expected non-zero exit when closes-issues-count=1 and History Notes is placeholder only (got exit 0)"
fi

echo "--- F23: CLOSES_ISSUES_COUNT=2 + 1 History bullet → exit 0 with count-mismatch warning ---"
_f23_repo="$(setup_test_repo)"
_f23_notes="$(make_notes "- Only one history bullet" "- Changelog entry")"
_f23_out="$(run_cli "$_f23_repo" --notes "$_f23_notes" --branch "feat/436" --pr "42" --background "F23 bg" --closes-issues-count 2 --dry-run 2>&1)"
_f23_exit=$?
if [ "$_f23_exit" -eq 0 ] && echo "$_f23_out" | grep -qi "mismatch\|warning"; then
    pass "F23: --closes-issues-count 2 + 1 bullet → exit 0 with mismatch warning"
else
    fail "F23: expected exit 0 with mismatch warning (exit=$_f23_exit, out='$_f23_out')"
fi

echo "--- F24: CLOSES_ISSUES_COUNT=2 + 2 History bullets → exit 0 without count-mismatch warning ---"
_f24_repo="$(setup_test_repo)"
_f24_notes="$(make_notes "- First history bullet
- Second history bullet" "- Changelog entry")"
_f24_out="$(run_cli "$_f24_repo" --notes "$_f24_notes" --branch "feat/436" --pr "42" --background "F24 bg" --closes-issues-count 2 --dry-run 2>&1)"
_f24_exit=$?
if [ "$_f24_exit" -eq 0 ] && ! echo "$_f24_out" | grep -qi "mismatch"; then
    pass "F24: --closes-issues-count 2 + 2 bullets → exit 0 without mismatch warning"
else
    fail "F24: expected exit 0 without mismatch warning (exit=$_f24_exit, out='$_f24_out')"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
