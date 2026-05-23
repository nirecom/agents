#!/bin/bash
# tests/feature-436-compose-doc-append.sh
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

echo "--- F3: History Notes only ---"
_f3_repo="$(setup_test_repo)"
_f3_notes="$(make_notes "- History bullet 1" "- (none)")"
_f3_before="$(commit_count_since_init "$_f3_repo")"
run_cli "$_f3_repo" --notes "$_f3_notes" --branch "feat/436" --pr "42" --background "Test background"
_f3_exit=$?
_f3_after="$(commit_count_since_init "$_f3_repo")"
_f3_last_subject="$(git -C "$_f3_repo" log -1 --pretty=%s)"
_f3_history_content="$(cat "$_f3_repo/docs/history.md")"
if [ "$_f3_exit" -eq 0 ] && \
   [ "$_f3_after" -eq $((_f3_before + 1)) ] && \
   [ "$_f3_last_subject" = "docs(history): record PR #42" ] && \
   echo "$_f3_history_content" | grep -q "History bullet 1"; then
    pass "F3: History Notes only → one commit docs(history): record PR #42 with bullet in docs/history.md"
else
    fail "F3: History Notes only (exit=$_f3_exit, before=$_f3_before, after=$_f3_after, subject='$_f3_last_subject', has_bullet=$(echo "$_f3_history_content" | grep -c "History bullet 1"))"
fi

echo "--- F4: Changelog Notes only ---"
_f4_repo="$(setup_test_repo)"
_f4_notes="$(make_notes "- (none)" "- Changelog bullet 1")"
_f4_before="$(commit_count_since_init "$_f4_repo")"
run_cli "$_f4_repo" --notes "$_f4_notes" --branch "feat/436" --pr "42" --background "Test background"
_f4_exit=$?
_f4_after="$(commit_count_since_init "$_f4_repo")"
_f4_last_subject="$(git -C "$_f4_repo" log -1 --pretty=%s)"
_f4_git_common="$(git_common_abs "$_f4_repo")"
_f4_marker_dir="$_f4_git_common/compose-doc-append-state"
_f4_marker_count="$(ls "$_f4_marker_dir" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$_f4_exit" -eq 0 ] && \
   [ "$_f4_after" -eq $((_f4_before + 1)) ] && \
   [ "$_f4_last_subject" = "docs(changelog): record PR #42" ] && \
   [ "$_f4_marker_count" -ge 1 ]; then
    pass "F4: Changelog Notes only → one commit docs(changelog): record PR #42 + marker file"
else
    fail "F4: Changelog Notes only (exit=$_f4_exit, before=$_f4_before, after=$_f4_after, subject='$_f4_last_subject', markers=$_f4_marker_count)"
fi

echo "--- F5: Both sections populated ---"
_f5_repo="$(setup_test_repo)"
_f5_notes="$(make_notes "- History F5" "- Changelog F5")"
_f5_before="$(commit_count_since_init "$_f5_repo")"
run_cli "$_f5_repo" --notes "$_f5_notes" --branch "feat/436" --pr "42" --background "F5 background"
_f5_exit=$?
_f5_after="$(commit_count_since_init "$_f5_repo")"
_f5_subjects="$(git -C "$_f5_repo" log --pretty=%s -2 | tr '\n' '|')"
if [ "$_f5_exit" -eq 0 ] && \
   [ "$_f5_after" -eq $((_f5_before + 2)) ] && \
   echo "$_f5_subjects" | grep -q "docs(history): record PR #42" && \
   echo "$_f5_subjects" | grep -q "docs(changelog): record PR #42"; then
    pass "F5: Both sections → two commits (history + changelog)"
else
    fail "F5: Both sections (exit=$_f5_exit, before=$_f5_before, after=$_f5_after, subjects='$_f5_subjects')"
fi

echo "--- F6: idempotency re-run ---"
# Use same repo from F3
_f6_before="$(commit_count_since_init "$_f3_repo")"
run_cli "$_f3_repo" --notes "$_f3_notes" --branch "feat/436" --pr "42" --background "Test background"
_f6_exit=$?
_f6_after="$(commit_count_since_init "$_f3_repo")"
if [ "$_f6_exit" -eq 0 ] && [ "$_f6_after" -eq "$_f6_before" ]; then
    pass "F6: re-run same branch/pr → idempotency sentinel found, no new commits"
else
    fail "F6: idempotency re-run (exit=$_f6_exit, before=$_f6_before, after=$_f6_after)"
fi

echo "--- F7: CHANGELOG.md missing ---"
_f7_repo="$(setup_test_repo)"
rm -f "$_f7_repo/CHANGELOG.md"
git -C "$_f7_repo" rm CHANGELOG.md --quiet 2>/dev/null || true
git -C "$_f7_repo" -c user.email=a@b -c user.name=a commit --no-verify -m "remove changelog" >/dev/null 2>&1 || true
git -C "$_f7_repo" push origin main >/dev/null 2>&1 || true
_f7_notes="$(make_notes "- History F7" "- Changelog F7")"
_f7_before="$(commit_count_since_init "$_f7_repo")"
_f7_stderr="$(run_cli "$_f7_repo" --notes "$_f7_notes" --branch "feat/436" --pr "42" --background "F7 background" 2>&1 1>/dev/null)"
_f7_exit=$?
_f7_after="$(commit_count_since_init "$_f7_repo")"
_f7_history="$(cat "$_f7_repo/docs/history.md" 2>/dev/null || echo "")"
if [ "$_f7_exit" -eq 0 ] && \
   echo "$_f7_stderr" | grep -qi "CHANGELOG" && \
   echo "$_f7_history" | grep -q "History F7"; then
    pass "F7: CHANGELOG.md missing → stderr warning, history processed, changelog skipped"
else
    fail "F7: CHANGELOG.md missing (exit=$_f7_exit, stderr='$_f7_stderr', history has_bullet=$(echo "$_f7_history" | grep -c "History F7"))"
fi

echo "--- F8: sentinel in rotated archive ---"
_f8_repo="$(setup_test_repo)"
mkdir -p "$_f8_repo/docs/history"
echo "<!-- compose-doc-append-sentinel: branch=feat/436 pr=#42 -->" > "$_f8_repo/docs/history/2024.md"
git -C "$_f8_repo" add docs/history/2024.md
git -C "$_f8_repo" -c user.email=a@b -c user.name=a commit --no-verify -m "archive" >/dev/null
git -C "$_f8_repo" push origin main >/dev/null 2>&1
_f8_notes="$(make_notes "- History F8" "- (none)")"
_f8_before="$(commit_count_since_init "$_f8_repo")"
run_cli "$_f8_repo" --notes "$_f8_notes" --branch "feat/436" --pr "42"
_f8_exit=$?
_f8_after="$(commit_count_since_init "$_f8_repo")"
if [ "$_f8_exit" -eq 0 ] && [ "$_f8_after" -eq "$_f8_before" ]; then
    pass "F8: sentinel in rotated archive → idempotency-skipped, no new commits"
else
    fail "F8: sentinel in archive (exit=$_f8_exit, before=$_f8_before, after=$_f8_after)"
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

echo "--- F12: --background custom text ---"
_f12_repo="$(setup_test_repo)"
_f12_notes="$(make_notes "- F12 history bullet" "- (none)")"
run_cli "$_f12_repo" --notes "$_f12_notes" --branch "feat/436" --pr "42" --background "Custom background text"
_f12_exit=$?
_f12_history="$(cat "$_f12_repo/docs/history.md" 2>/dev/null || echo "")"
if [ "$_f12_exit" -eq 0 ] && echo "$_f12_history" | grep -q "Custom background text"; then
    pass "F12: --background text appears in docs/history.md"
else
    fail "F12: --background (exit=$_f12_exit, has_background=$(echo "$_f12_history" | grep -c "Custom background text"))"
fi

echo "--- F13: fallback background when gh unavailable ---"
_f13_repo="$(setup_test_repo)"
_f13_notes="$(make_notes "- F13 history" "- (none)")"
# Run CLI without --background, with gh not in PATH
_f13_path_no_gh="$(echo "$PATH" | tr ':' '\n' | grep -v "gh" | tr '\n' ':')"
(cd "$_f13_repo" && COMPOSE_DOC_APPEND_SKILL=1 PATH="$_f13_path_no_gh" run_with_timeout 30 bash "$CLI" --notes "$_f13_notes" --branch "feat/436" --pr "42")
_f13_exit=$?
_f13_history="$(cat "$_f13_repo/docs/history.md" 2>/dev/null || echo "")"
_f13_today="$(date +%F)"
if [ "$_f13_exit" -eq 0 ] && echo "$_f13_history" | grep -q "PR #42 merged on $_f13_today"; then
    pass "F13: gh unavailable → fallback 'PR #42 merged on <date>' used"
else
    fail "F13: fallback background (exit=$_f13_exit, today=$_f13_today, has_fallback=$(echo "$_f13_history" | grep -c "PR #42 merged on"))"
fi

echo "--- F14: --merge-commit in history entry ---"
_f14a_repo="$(setup_test_repo)"
_f14_notes="$(make_notes "- F14 history" "- (none)")"
run_cli "$_f14a_repo" --notes "$_f14_notes" --branch "feat/436" --pr "42" --merge-commit "abc1234" --background "F14 bg"
_f14a_exit=$?
_f14a_history="$(cat "$_f14a_repo/docs/history.md" 2>/dev/null || echo "")"

_f14b_repo="$(setup_test_repo)"
run_cli "$_f14b_repo" --notes "$_f14_notes" --branch "feat/436" --pr "42" --background "F14 bg"
_f14b_exit=$?
_f14b_history="$(cat "$_f14b_repo/docs/history.md" 2>/dev/null || echo "")"

if [ "$_f14a_exit" -eq 0 ] && echo "$_f14a_history" | grep -q "abc1234" && \
   [ "$_f14b_exit" -eq 0 ] && ! echo "$_f14b_history" | grep -q "abc1234"; then
    pass "F14: --merge-commit sha appears in history entry; without it, sha absent"
else
    fail "F14: merge-commit (a_exit=$_f14a_exit, a_has_sha=$(echo "$_f14a_history" | grep -c abc1234), b_exit=$_f14b_exit, b_no_sha=$(echo "$_f14b_history" | grep -c abc1234))"
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

echo "--- F18: --skip-history with both sections → changelog-only commit ---"
_f18_repo="$(setup_test_repo)"
_f18_notes="$(make_notes "- History F18 (should be skipped)" "- Changelog F18")"
_f18_before="$(commit_count_since_init "$_f18_repo")"
run_cli "$_f18_repo" --notes "$_f18_notes" --branch "feat/436" --pr "42" --background "F18 bg" --skip-history
_f18_exit=$?
_f18_after="$(commit_count_since_init "$_f18_repo")"
_f18_subjects="$(git -C "$_f18_repo" log --pretty=%s -2 | tr '\n' '|')"
_f18_history="$(cat "$_f18_repo/docs/history.md")"
_f18_changelog="$(cat "$_f18_repo/CHANGELOG.md")"
if [ "$_f18_exit" -eq 0 ] && \
   [ "$_f18_after" -eq $((_f18_before + 1)) ] && \
   echo "$_f18_subjects" | grep -q "docs(changelog): record PR #42" && \
   ! echo "$_f18_subjects" | grep -q "docs(history): record PR #42" && \
   ! echo "$_f18_history" | grep -q "History F18" && \
   echo "$_f18_changelog" | grep -q "Changelog F18"; then
    pass "F18: --skip-history → only changelog commit, history.md untouched"
else
    fail "F18: --skip-history (exit=$_f18_exit, before=$_f18_before, after=$_f18_after, subjects='$_f18_subjects', history_has_f18=$(echo "$_f18_history" | grep -c "History F18"), changelog_has_f18=$(echo "$_f18_changelog" | grep -c "Changelog F18"))"
fi

echo "--- F19: --skip-history with History Notes only → no commits ---"
_f19_repo="$(setup_test_repo)"
_f19_notes="$(make_notes "- History F19 (should be skipped)" "- (none)")"
_f19_before="$(commit_count_since_init "$_f19_repo")"
run_cli "$_f19_repo" --notes "$_f19_notes" --branch "feat/436" --pr "42" --skip-history
_f19_exit=$?
_f19_after="$(commit_count_since_init "$_f19_repo")"
_f19_history="$(cat "$_f19_repo/docs/history.md")"
if [ "$_f19_exit" -eq 0 ] && \
   [ "$_f19_after" -eq "$_f19_before" ] && \
   ! echo "$_f19_history" | grep -q "History F19"; then
    pass "F19: --skip-history + history only → no commits, history.md untouched"
else
    fail "F19: --skip-history history-only (exit=$_f19_exit, before=$_f19_before, after=$_f19_after, history_has_f19=$(echo "$_f19_history" | grep -c "History F19"))"
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
