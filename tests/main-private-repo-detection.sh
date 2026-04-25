#!/bin/bash
# Test suite for private repo dynamic detection (is-private-repo.js + hook integration)
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Convert MSYS paths to mixed paths (C:/...) for Node.js on Windows
if command -v cygpath >/dev/null 2>&1; then
  DOTFILES_DIR="$(cygpath -m "$DOTFILES_DIR")"
fi
LIB="$DOTFILES_DIR/claude-global/hooks/lib/is-private-repo.js"
HOOK_PRIVATE="$DOTFILES_DIR/claude-global/hooks/scan-outbound.js"
HOOK_DOCS="$DOTFILES_DIR/claude-global/hooks/check-docs-updated.js"
HOOK_TEST="$DOTFILES_DIR/claude-global/hooks/check-tests-updated.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# --- Mock gh CLI ---
# Create mock gh that returns configurable responses
# On Windows, Node.js execSync uses cmd.exe, so we need .cmd files
MOCK_BIN="$TMPDIR_BASE/mock-bin"
mkdir -p "$MOCK_BIN"

# Default mock: repo is public (returns "false")
setup_mock_gh_public() {
    printf '@echo off\r\necho false\r\n' > "$MOCK_BIN/gh.cmd"
    printf '#!/bin/bash\necho "false"\n' > "$MOCK_BIN/gh"
    chmod +x "$MOCK_BIN/gh"
}

# Mock: repo is private (returns "true")
setup_mock_gh_private() {
    printf '@echo off\r\necho true\r\n' > "$MOCK_BIN/gh.cmd"
    printf '#!/bin/bash\necho "true"\n' > "$MOCK_BIN/gh"
    chmod +x "$MOCK_BIN/gh"
}

# Mock: gh fails (network error, auth error, etc.)
setup_mock_gh_error() {
    printf '@echo off\r\necho gh: Not Found (HTTP 404) 1>&2\r\nexit /b 1\r\n' > "$MOCK_BIN/gh.cmd"
    printf '#!/bin/bash\necho "gh: Not Found (HTTP 404)" >&2\nexit 1\n' > "$MOCK_BIN/gh"
    chmod +x "$MOCK_BIN/gh"
}

# Mock: gh not found (remove from PATH)
setup_mock_gh_missing() {
    rm -f "$MOCK_BIN/gh" "$MOCK_BIN/gh.cmd"
}

# Convert MOCK_BIN to Windows path for Node.js PATH prepend
if command -v cygpath >/dev/null 2>&1; then
  MOCK_BIN_WIN="$(cygpath -w "$MOCK_BIN")"
else
  MOCK_BIN_WIN="$MOCK_BIN"
fi

# Run node with mock gh in PATH (works on both Windows and Unix)
run_node_with_mock() {
    PATH="$MOCK_BIN:$PATH" node "$@"
}

# Helper: create a git repo with a remote
# Returns mixed path (C:/...) on Windows for Node.js compatibility
setup_repo() {
    local repo="$TMPDIR_BASE/repo-$RANDOM"
    mkdir -p "$repo/src" "$repo/docs" "$repo/tests"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" remote add origin "git@github.com:testowner/testrepo.git"
    echo "init" > "$repo/README.md"
    echo "# docs" > "$repo/docs/history.md"
    echo "# test" > "$repo/tests/test.sh"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "initial"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$repo"
    else
        echo "$repo"
    fi
}

# =====================================================================
# Unit tests: is-private-repo.js module
# =====================================================================

echo "=== Unit: extractRepoId ==="

run_extract() {
    node -e "
const { extractRepoId } = require('$LIB');
console.log(extractRepoId('$1') || 'null');
"
}

result=$(run_extract "git@github.com:owner/repo.git")
if [ "$result" = "owner/repo" ]; then pass "SSH URL with .git"
else fail "SSH URL with .git — got: $result"; fi

result=$(run_extract "https://github.com/owner/repo.git")
if [ "$result" = "owner/repo" ]; then pass "HTTPS URL with .git"
else fail "HTTPS URL with .git — got: $result"; fi

result=$(run_extract "git@github.com:owner/repo")
if [ "$result" = "owner/repo" ]; then pass "SSH URL without .git"
else fail "SSH URL without .git — got: $result"; fi

result=$(run_extract "https://github.com/owner/repo")
if [ "$result" = "owner/repo" ]; then pass "HTTPS URL without .git"
else fail "HTTPS URL without .git — got: $result"; fi

result=$(run_extract "")
if [ "$result" = "null" ]; then pass "empty URL"
else fail "empty URL — got: $result"; fi

echo ""
echo "=== Unit: extractHost ==="

run_extract_host() {
    node -e "
const { extractHost } = require('$LIB');
console.log(extractHost('$1') || 'null');
"
}

result=$(run_extract_host "git@github.com:owner/repo.git")
if [ "$result" = "github.com" ]; then pass "SSH github.com"
else fail "SSH github.com — got: $result"; fi

result=$(run_extract_host "https://github.com/owner/repo.git")
if [ "$result" = "github.com" ]; then pass "HTTPS github.com"
else fail "HTTPS github.com — got: $result"; fi

result=$(run_extract_host "git@gitlab.example.com:owner/repo.git")
if [ "$result" = "gitlab.example.com" ]; then pass "SSH GitLab"
else fail "SSH GitLab — got: $result"; fi

result=$(run_extract_host "https://gitlab.example.com/owner/repo.git")
if [ "$result" = "gitlab.example.com" ]; then pass "HTTPS GitLab"
else fail "HTTPS GitLab — got: $result"; fi

result=$(run_extract_host "ssh://git@gitlab.example.com:2222/owner/repo.git")
if [ "$result" = "gitlab.example.com" ]; then pass "SSH with custom port"
else fail "SSH with custom port — got: $result"; fi

result=$(run_extract_host "git@github.company.com:owner/repo.git")
if [ "$result" = "github.company.com" ]; then pass "github subdomain (not github.com)"
else fail "github subdomain — got: $result"; fi

result=$(run_extract_host "git@bitbucket.org:owner/repo.git")
if [ "$result" = "bitbucket.org" ]; then pass "Bitbucket"
else fail "Bitbucket — got: $result"; fi

result=$(run_extract_host "")
if [ "$result" = "null" ]; then pass "empty URL"
else fail "empty URL — got: $result"; fi

echo ""
echo "=== Unit: extractRepoDirFromCommand ==="

run_extract_dir() {
    node -e "
const { extractRepoDirFromCommand } = require('$LIB');
console.log(extractRepoDirFromCommand('$1') || 'null');
"
}

result=$(run_extract_dir "git -C /some/path commit -m msg")
if [ "$result" = "/some/path" ]; then pass "git -C path extraction"
else fail "git -C path extraction — got: $result"; fi

result=$(run_extract_dir "git commit -m msg")
if [ "$result" = "null" ]; then pass "no -C flag"
else fail "no -C flag — got: $result"; fi

echo ""
echo "=== Unit: isPrivateRepo with mock gh ==="

# Private repo
setup_mock_gh_private
REPO=$(setup_repo)
result=$(PATH="$MOCK_BIN:$PATH" node -e "
const { isPrivateRepo } = require('$LIB');
console.log(isPrivateRepo('$REPO'));
")
if [ "$result" = "true" ]; then pass "private repo detected"
else fail "private repo detected — got: $result"; fi

# Public repo
setup_mock_gh_public
REPO=$(setup_repo)
result=$(PATH="$MOCK_BIN:$PATH" node -e "
const { isPrivateRepo } = require('$LIB');
console.log(isPrivateRepo('$REPO'));
")
if [ "$result" = "false" ]; then pass "public repo detected"
else fail "public repo detected — got: $result"; fi

# gh error → fail-open (false)
setup_mock_gh_error
REPO=$(setup_repo)
result=$(PATH="$MOCK_BIN:$PATH" node -e "
const { isPrivateRepo } = require('$LIB');
console.log(isPrivateRepo('$REPO'));
")
if [ "$result" = "false" ]; then pass "gh error → fail-open"
else fail "gh error → fail-open — got: $result"; fi

# gh missing → fail-open (false)
setup_mock_gh_missing
REPO=$(setup_repo)
result=$(PATH="$MOCK_BIN:$PATH" node -e "
const { isPrivateRepo } = require('$LIB');
console.log(isPrivateRepo('$REPO'));
")
if [ "$result" = "false" ]; then pass "gh missing → fail-open"
else fail "gh missing → fail-open — got: $result"; fi

# No remote → fail-open (false)
setup_mock_gh_private
REPO_NO_REMOTE="$TMPDIR_BASE/repo-no-remote-$RANDOM"
mkdir -p "$REPO_NO_REMOTE"
git -C "$REPO_NO_REMOTE" init -q
if command -v cygpath >/dev/null 2>&1; then REPO_NO_REMOTE="$(cygpath -m "$REPO_NO_REMOTE")"; fi
result=$(PATH="$MOCK_BIN:$PATH" node -e "
const { isPrivateRepo } = require('$LIB');
console.log(isPrivateRepo('$REPO_NO_REMOTE'));
")
if [ "$result" = "false" ]; then pass "no remote → fail-open"
else fail "no remote → fail-open — got: $result"; fi

# Invalid path → fail-open (false)
result=$(PATH="$MOCK_BIN:$PATH" node -e "
const { isPrivateRepo } = require('$LIB');
console.log(isPrivateRepo('/nonexistent/path'));
")
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

# Non-GitHub remote → treat as private (true) regardless of gh response
setup_mock_gh_public
REPO_GITLAB="$TMPDIR_BASE/repo-gitlab-$RANDOM"
mkdir -p "$REPO_GITLAB"
git -C "$REPO_GITLAB" init -q
git -C "$REPO_GITLAB" config user.email "test@example.com"
git -C "$REPO_GITLAB" config user.name "Test"
git -C "$REPO_GITLAB" remote add origin "git@gitlab.example.com:team/project.git"
if command -v cygpath >/dev/null 2>&1; then REPO_GITLAB="$(cygpath -m "$REPO_GITLAB")"; fi
result=$(PATH="$MOCK_BIN:$PATH" node -e "
const { isPrivateRepo } = require('$LIB');
console.log(isPrivateRepo('$REPO_GITLAB'));
")
if [ "$result" = "true" ]; then pass "GitLab repo → treat as private"
else fail "GitLab repo → treat as private — got: $result"; fi

# Non-GitHub with custom port SSH URL
setup_mock_gh_public
REPO_CUSTOM="$TMPDIR_BASE/repo-custom-$RANDOM"
mkdir -p "$REPO_CUSTOM"
git -C "$REPO_CUSTOM" init -q
git -C "$REPO_CUSTOM" config user.email "test@example.com"
git -C "$REPO_CUSTOM" config user.name "Test"
git -C "$REPO_CUSTOM" remote add origin "ssh://git@gitlab.example.com:2222/team/project.git"
if command -v cygpath >/dev/null 2>&1; then REPO_CUSTOM="$(cygpath -m "$REPO_CUSTOM")"; fi
result=$(PATH="$MOCK_BIN:$PATH" node -e "
const { isPrivateRepo } = require('$LIB');
console.log(isPrivateRepo('$REPO_CUSTOM'));
")
if [ "$result" = "true" ]; then pass "custom port SSH → treat as private"
else fail "custom port SSH → treat as private — got: $result"; fi

# github.company.com (not github.com) → treat as private
setup_mock_gh_public
REPO_GHE="$TMPDIR_BASE/repo-ghe-$RANDOM"
mkdir -p "$REPO_GHE"
git -C "$REPO_GHE" init -q
git -C "$REPO_GHE" config user.email "test@example.com"
git -C "$REPO_GHE" config user.name "Test"
git -C "$REPO_GHE" remote add origin "git@github.company.com:team/project.git"
if command -v cygpath >/dev/null 2>&1; then REPO_GHE="$(cygpath -m "$REPO_GHE")"; fi
result=$(PATH="$MOCK_BIN:$PATH" node -e "
const { isPrivateRepo } = require('$LIB');
console.log(isPrivateRepo('$REPO_GHE'));
")
if [ "$result" = "true" ]; then pass "github.company.com → treat as private"
else fail "github.company.com → treat as private — got: $result"; fi

# =====================================================================
# Integration tests: hook behavior with private/public repos
# =====================================================================

run_hook() {
    local hook="$1" json="$2" repo="$3"
    echo "$json" | PATH="$MOCK_BIN:$PATH" HOOK_CWD="$repo" node "$hook" 2>/dev/null
}

expect_approve() {
    local desc="$1" hook="$2" json="$3" repo="$4"
    local result
    result=$(run_hook "$hook" "$json" "$repo")
    if echo "$result" | grep -q '"approve"'; then pass "$desc"
    else fail "$desc — expected approve, got: $result"; fi
}

expect_block() {
    local desc="$1" hook="$2" json="$3" repo="$4"
    local result
    result=$(run_hook "$hook" "$json" "$repo")
    if echo "$result" | grep -q '"block"'; then pass "$desc"
    else fail "$desc — expected block, got: $result"; fi
}

COMMIT_JSON='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"update\""}}'

echo ""
echo "=== Integration: scan-outbound.js ==="

# Private repo: commit with private-looking content → approve (skipped)
setup_mock_gh_private
REPO=$(setup_repo)
COMMIT_WITH_PRIVATE='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix 192.168.1.1 issue\""}}'
expect_approve "private repo — commit with IP address → approve" "$HOOK_PRIVATE" "$COMMIT_WITH_PRIVATE" "$REPO"

# Public repo: commit with private-looking content → block
setup_mock_gh_public
REPO=$(setup_repo)
expect_block "public repo — commit with IP address → block" "$HOOK_PRIVATE" "$COMMIT_WITH_PRIVATE" "$REPO"

# Private repo via git -C: approve
setup_mock_gh_private
REPO=$(setup_repo)
GIT_C_COMMIT="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO commit -m \\\"fix 192.168.1.1\\\"\"}}"
expect_approve "private repo via git -C → approve" "$HOOK_PRIVATE" "$GIT_C_COMMIT" "$REPO"

# GitLab repo: commit with private info → approve (non-GitHub = private)
setup_mock_gh_public
REPO_GL=$(setup_repo)
git -C "$REPO_GL" remote set-url origin "git@gitlab.example.com:team/project.git"
expect_approve "GitLab repo — commit with IP address → approve" "$HOOK_PRIVATE" "$COMMIT_WITH_PRIVATE" "$REPO_GL"

echo ""
echo "=== Integration: check-docs-updated.js ==="

# Private repo: code without docs → approve (skipped)
setup_mock_gh_private
REPO=$(setup_repo)
echo "new code" > "$REPO/src/app.js"
git -C "$REPO" add src/app.js
expect_approve "private repo — code without docs → approve" "$HOOK_DOCS" "$COMMIT_JSON" "$REPO"

# Public repo: code without docs → block
setup_mock_gh_public
REPO=$(setup_repo)
echo "new code" > "$REPO/src/app.js"
git -C "$REPO" add src/app.js
expect_block "public repo — code without docs → block" "$HOOK_DOCS" "$COMMIT_JSON" "$REPO"

echo ""
echo "=== Integration: check-tests-updated.js ==="

# Private repo: code without tests → approve (skipped)
setup_mock_gh_private
REPO=$(setup_repo)
echo "new code" > "$REPO/src/app.js"
git -C "$REPO" add src/app.js
expect_approve "private repo — code without tests → approve" "$HOOK_TEST" "$COMMIT_JSON" "$REPO"

# Public repo: code without tests → block
setup_mock_gh_public
REPO=$(setup_repo)
echo "new code" > "$REPO/src/app.js"
git -C "$REPO" add src/app.js
expect_block "public repo — code without tests → block" "$HOOK_TEST" "$COMMIT_JSON" "$REPO"

echo ""
echo "=== Integration: idempotency ==="
setup_mock_gh_private
REPO=$(setup_repo)
echo "new code" > "$REPO/src/app.js"
git -C "$REPO" add src/app.js
result1=$(run_hook "$HOOK_DOCS" "$COMMIT_JSON" "$REPO")
result2=$(run_hook "$HOOK_DOCS" "$COMMIT_JSON" "$REPO")
if [ "$result1" = "$result2" ]; then pass "idempotent: same result on repeated calls"
else fail "idempotent — results differ: $result1 vs $result2"; fi

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
