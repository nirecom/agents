#!/bin/bash
# Tests: bin/is-github-dotcom-remote, bin/is-github-dotcom-remote.
# Tags: bin, windows, tests
# Integration tests for bin/is-github-dotcom-remote.
# Pre-implementation: all tests expected to FAIL until bin/is-github-dotcom-remote lands.
set -u

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$AGENTS_DIR/bin/is-github-dotcom-remote"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
    else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# Windows-compatible tmpdir
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/cctests.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Make a fresh temp git repo. If $2 is provided, set it as origin URL.
make_repo() {
    local name="$1"
    local url="${2-}"
    local dir="$TMPDIR_BASE/$name"
    mkdir -p "$dir"
    (
        cd "$dir"
        git init -q
        git config user.email test@example.com
        git config user.name Test
        if [ -n "$url" ]; then
            git remote add origin "$url"
        fi
    )
    printf '%s' "$dir"
}

# Run the helper from inside the given dir; print exit code via stdout.
run_helper_in() {
    local dir="$1"
    (
        cd "$dir"
        run_with_timeout bash "$HELPER" >/dev/null 2>&1
        echo $?
    )
}

# assert_exit <test_name> <repo_name> <url|""> <expected_rc>
assert_exit() {
    local test_name="$1" repo_name="$2" url="$3" expected="$4"
    local dir rc
    dir=$(make_repo "$repo_name" "$url")
    rc=$(run_helper_in "$dir")
    if [ "$rc" = "$expected" ]; then
        pass "$test_name"
    else
        fail "$test_name (expected=$expected, got=$rc, url='$url')"
    fi
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# 1. SSH github.com .git
assert_exit "ssh_github_dotgit"          "r01" "git@github.com:owner/repo.git"            0

# 2. HTTPS github.com .git
assert_exit "https_github_dotgit"        "r02" "https://github.com/owner/repo.git"        0

# 3. HTTPS github.com no .git
assert_exit "https_github_no_dotgit"     "r03" "https://github.com/owner/repo"            0

# 4. SSH github.com no .git
assert_exit "ssh_github_no_dotgit"       "r04" "git@github.com:owner/repo"                0

# 5. HTTPS with userinfo
assert_exit "https_github_userinfo"      "r05" "https://user@github.com/owner/repo.git"   0

# 6. SSH gitlab.com
assert_exit "ssh_gitlab"                 "r06" "git@gitlab.com:owner/repo.git"            1

# 7. HTTPS bitbucket.org
assert_exit "https_bitbucket"            "r07" "https://bitbucket.org/owner/repo.git"     1

# 8. SSH internal host
assert_exit "ssh_internal_host"          "r08" "git@example.internal:owner/repo.git"      1

# 9. Mixed-case GitHub.COM (case-insensitive)
assert_exit "ssh_mixed_case"             "r09" "git@GitHub.COM:owner/repo.git"            0

# 10. HTTPS with port 443 (port strip)
assert_exit "https_github_port443"       "r10" "https://github.com:443/owner/repo.git"    0

# 11. SSH subdomain confusion
assert_exit "ssh_subdomain_evil"         "r11" "git@github.com.evil.com:owner/repo.git"   1

# 12. HTTPS subdomain confusion
assert_exit "https_subdomain_evil"       "r12" "https://github.com.evil.com/owner/repo.git" 1

# 13. SSH prefix match
assert_exit "ssh_prefix_notgithub"       "r13" "git@notgithub.com:owner/repo.git"         1

# 14. No remote configured (empty git repo, no origin)
assert_exit "no_remote_configured"       "r14" ""                                         2

# ---------------------------------------------------------------------------
echo
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed."
else
    echo "$ERRORS test(s) failed."
fi
exit "$ERRORS"
