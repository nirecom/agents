# ===========================================================================
# Tests: hooks/scan-outbound.js
# Tags: scan, filter, outbound, hook, tests, scope:common
#
# Integration: scan-outbound.js visibility gating
#
# The hook resolves the repo through resolveRepoDir(), which reads
# CLAUDE_PROJECT_DIR first and falls back to `git -C <path>` in the command —
# HOOK_CWD is consulted only on the forge-write branch, not on git commit.
# Pinning CLAUDE_PROJECT_DIR is therefore what makes these cases target the
# fixture repo instead of the repo the test runner happens to sit in.
#
# Retired here: the former check-docs-updated.js / check-tests-updated.js
# sections. Both hooks were replaced by workflow-gate.js and no longer exist
# under hooks/, so their assertions covered removed code.
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
echo "=== Integration: idempotency ==="
setup_mock_gh_private
REPO=$(setup_repo)
result1=$(run_hook "$HOOK_PRIVATE" "$COMMIT_WITH_PRIVATE" "$REPO")
result2=$(run_hook "$HOOK_PRIVATE" "$COMMIT_WITH_PRIVATE" "$REPO")
if [ "$result1" = "$result2" ]; then pass "idempotent: same result on repeated calls"
else fail "idempotent — results differ: $result1 vs $result2"; fi
