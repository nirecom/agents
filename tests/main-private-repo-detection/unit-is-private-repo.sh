# ===========================================================================
# Tests: hooks/lib/is-private-repo.js
# Tags: scan, filter, outbound, hook, tests, scope:common
#
# Unit tests: isPrivateRepo() against a mocked gh CLI
# ===========================================================================

echo ""
echo "=== Unit: isPrivateRepo with mock gh ==="

# Private repo
setup_mock_gh_private
REPO=$(setup_repo)
result=$(run_is_private_repo "$REPO")
if [ "$result" = "true" ]; then pass "private repo detected"
else fail "private repo detected — got: $result"; fi

# Public repo
setup_mock_gh_public
REPO=$(setup_repo)
result=$(run_is_private_repo "$REPO")
if [ "$result" = "false" ]; then pass "public repo detected"
else fail "public repo detected — got: $result"; fi

# gh error → fail-open (false)
setup_mock_gh_error
REPO=$(setup_repo)
result=$(run_is_private_repo "$REPO")
if [ "$result" = "false" ]; then pass "gh error → fail-open"
else fail "gh error → fail-open — got: $result"; fi

# gh missing → fail-open (false)
setup_mock_gh_missing
REPO=$(setup_repo)
result=$(run_is_private_repo "$REPO")
if [ "$result" = "false" ]; then pass "gh missing → fail-open"
else fail "gh missing → fail-open — got: $result"; fi

# No remote → fail-open (false)
setup_mock_gh_private
REPO_NO_REMOTE="$TMPDIR_BASE/repo-no-remote-$RANDOM"
mkdir -p "$REPO_NO_REMOTE"
git -C "$REPO_NO_REMOTE" init -q
git -C "$REPO_NO_REMOTE" config core.hooksPath /dev/null 2>/dev/null || true
if command -v cygpath >/dev/null 2>&1; then REPO_NO_REMOTE="$(cygpath -m "$REPO_NO_REMOTE")"; fi
result=$(run_is_private_repo "$REPO_NO_REMOTE")
if [ "$result" = "false" ]; then pass "no remote → fail-open"
else fail "no remote → fail-open — got: $result"; fi

# Invalid path → fail-open (false)
result=$(run_is_private_repo "/nonexistent/path")
if [ "$result" = "false" ]; then pass "invalid path → fail-open"
else fail "invalid path → fail-open — got: $result"; fi

# null/empty → fail-open (false)
result=$(node -e "
const { isPrivateRepo } = require('$LIB');
console.log(isPrivateRepo(null));
")
if [ "$result" = "false" ]; then pass "null repoDir → fail-open"
else fail "null repoDir → fail-open — got: $result"; fi

echo ""
echo "=== Unit: non-GitHub remotes → treat as private ==="

# Non-GitHub remote → treat as private (true) regardless of gh response.
# The mock answers "false" (public) throughout this block, so a `true` result
# can only come from the non-github-host branch, never from gh.
setup_mock_gh_public
REPO_GITLAB=$(setup_repo_with_origin "git@gitlab.example.com:team/project.git")
result=$(run_is_private_repo "$REPO_GITLAB")
if [ "$result" = "true" ]; then pass "GitLab repo → treat as private"
else fail "GitLab repo → treat as private — got: $result"; fi

# Non-GitHub with custom port SSH URL
setup_mock_gh_public
REPO_CUSTOM=$(setup_repo_with_origin "ssh://git@gitlab.example.com:2222/team/project.git")
result=$(run_is_private_repo "$REPO_CUSTOM")
if [ "$result" = "true" ]; then pass "custom port SSH → treat as private"
else fail "custom port SSH → treat as private — got: $result"; fi

# github.company.com (not github.com) → treat as private
setup_mock_gh_public
REPO_GHE=$(setup_repo_with_origin "git@github.company.com:team/project.git")
result=$(run_is_private_repo "$REPO_GHE")
if [ "$result" = "true" ]; then pass "github.company.com → treat as private"
else fail "github.company.com → treat as private — got: $result"; fi
