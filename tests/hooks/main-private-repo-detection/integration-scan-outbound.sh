# ===========================================================================
# Tests: hooks/scan-outbound.js
# Tags: scan, filter, outbound, hook, tests, scope:common
#
# Integration: scan-outbound.js visibility gating. The commit branch resolves its
# repo via resolveCommitRepoDir (`git -C`, else the process cwd); CLAUDE_PROJECT_DIR
# and HOOK_CWD are not read there, so run_hook launches the hook from the fixture repo.
# ===========================================================================

echo ""
echo "=== Integration: scan-outbound.js ==="

COMMIT_WITH_PRIVATE='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix 192.168.1.1 issue\""}}'

# Private repo: commit with private-looking content → approve (scan skipped)
setup_mock_gh_private
REPO=$(setup_repo)
expect_approve "private repo — commit with IP address → approve" "$HOOK_PRIVATE" "$COMMIT_WITH_PRIVATE" "$REPO"

# Public repo: same content → block
setup_mock_gh_public
REPO=$(setup_repo)
expect_block "public repo — commit with IP address → block" "$HOOK_PRIVATE" "$COMMIT_WITH_PRIVATE" "$REPO"

# Private repo addressed via git -C: approve
setup_mock_gh_private
REPO=$(setup_repo)
GIT_C_COMMIT="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO commit -m \\\"fix 192.168.1.1\\\"\"}}"
expect_approve "private repo via git -C → approve" "$HOOK_PRIVATE" "$GIT_C_COMMIT" "$REPO"

# GitLab repo: non-GitHub host is treated as private → approve, even though the
# gh mock reports public. A block here would mean the host branch was bypassed.
setup_mock_gh_public
REPO_GL=$(setup_repo_with_origin "git@gitlab.example.com:team/project.git")
expect_approve "GitLab repo — commit with IP address → approve" "$HOOK_PRIVATE" "$COMMIT_WITH_PRIVATE" "$REPO_GL"

# Malformed github.com origin: fail-open → public → block.
# This is the parse-failure arm observed through the hook rather than the module.
setup_mock_gh_private
REPO_BAD=$(setup_repo_with_origin "git@github.com:own_er/testrepo.git")
expect_block "unparsable owner/repo — commit with IP address → block (fail-open)" "$HOOK_PRIVATE" "$COMMIT_WITH_PRIVATE" "$REPO_BAD"

echo ""
echo "=== Integration: launch cwd independence (#2992) ==="
# A dirty caller cwd (no origin, a private IP staged) must not decide the fixture repo's verdict.
DIRTY_CWD="$TMPDIR_BASE/dirty-cwd"
mkdir -p "$DIRTY_CWD"
git -C "$DIRTY_CWD" init -q
git -C "$DIRTY_CWD" config core.hooksPath /dev/null
echo "host 10.20.30.40" > "$DIRTY_CWD/leak.txt"
git -C "$DIRTY_CWD" add leak.txt 2>/dev/null
STAGED_REASON="Private information detected in staged files"

setup_mock_gh_public
result=$(cd "$DIRTY_CWD" && run_hook "$HOOK_PRIVATE" "$COMMIT_WITH_PRIVATE" "$DIRTY_CWD")
case "$result" in
  *'"block"'*"$STAGED_REASON"*) pass "dirty-cwd control: its own staged IP blocks the commit" ;;
  *) fail "dirty-cwd control — expected staged-files block, got: $result" ;;
esac
result=$(cd "$DIRTY_CWD" && run_hook "$HOOK_PRIVATE" "$COMMIT_WITH_PRIVATE" "$REPO_GL")
case "$result" in
  *'"approve"'*) pass "dirty launch cwd — GitLab repo → approve" ;;
  *) fail "dirty launch cwd — GitLab repo — expected approve, got: $result" ;;
esac

setup_mock_gh_private
result=$(cd "$DIRTY_CWD" && run_hook "$HOOK_PRIVATE" "$COMMIT_WITH_PRIVATE" "$REPO_BAD")
case "$result" in
  *"$STAGED_REASON"*) fail "dirty launch cwd — unparsable — blocked by the caller's staged file: $result" ;;
  *'"block"'*'[IPv4] 192.168.1.1'*) pass "dirty launch cwd — unparsable owner/repo → block on the message" ;;
  *) fail "dirty launch cwd — unparsable — expected message block, got: $result" ;;
esac

echo ""
echo "=== Integration: idempotency ==="
setup_mock_gh_private
REPO=$(setup_repo)
result1=$(run_hook "$HOOK_PRIVATE" "$COMMIT_WITH_PRIVATE" "$REPO")
result2=$(run_hook "$HOOK_PRIVATE" "$COMMIT_WITH_PRIVATE" "$REPO")
if [ "$result1" = "$result2" ]; then pass "idempotent: same result on repeated calls"
else fail "idempotent — results differ: $result1 vs $result2"; fi
