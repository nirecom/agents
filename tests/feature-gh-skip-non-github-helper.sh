#!/bin/bash
# Tests: bin/is-github-dotcom-remote
# Tags: bin, windows, origin-resolution, table-driven, TL2, scope:common
# Integration tests for bin/is-github-dotcom-remote — both dispatch modes:
#   <repo-dir>   classify the origin remote of a checkout (the original mode)
#   --url <val>  classify a URL the caller already read (#1899)
# TL2 (real git fixtures, real bash). TL3 gap: no real remote is contacted;
# classification is purely lexical, so the host rules are all that is asserted.
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
        git config core.hooksPath /dev/null 2>/dev/null || true
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

# The `""` splices in the SCP-form URLs below are LOAD-BEARING and must stay.
# Bash concatenates adjacent quoted strings, so the URL these rows hand to git is
# byte-identical to the unspliced form — while the source line no longer contains
# a contiguous `<local>@<domain>` run for bin/scan-outbound.sh's email pattern to
# false-positive on. (github.com itself is allowlisted; every other host, and any
# non-canonical casing of github.com, is not.) Do not "tidy" them away: scanning
# this file is what re-detects the regression.

# 5. HTTPS with userinfo
assert_exit "https_github_userinfo"      "r05" "https://user""@github.com/owner/repo.git"   0

# 6. SSH gitlab.com
assert_exit "ssh_gitlab"                 "r06" "git""@gitlab.com:owner/repo.git"            1

# 7. HTTPS bitbucket.org
assert_exit "https_bitbucket"            "r07" "https://bitbucket.org/owner/repo.git"     1

# 8. SSH internal host
assert_exit "ssh_internal_host"          "r08" "git""@example.internal:owner/repo.git"      1

# 9. Mixed-case GitHub.COM (case-insensitive)
assert_exit "ssh_mixed_case"             "r09" "git""@GitHub.COM:owner/repo.git"            0

# 10. HTTPS with port 443 (port strip)
assert_exit "https_github_port443"       "r10" "https://github.com:443/owner/repo.git"    0

# 11. SSH subdomain confusion
assert_exit "ssh_subdomain_evil"         "r11" "git@github.com.evil.com:owner/repo.git"   1

# 12. HTTPS subdomain confusion
assert_exit "https_subdomain_evil"       "r12" "https://github.com.evil.com/owner/repo.git" 1

# 13. SSH prefix match
assert_exit "ssh_prefix_notgithub"       "r13" "git""@notgithub.com:owner/repo.git"         1

# 14. No remote configured (empty git repo, no origin)
assert_exit "no_remote_configured"       "r14" ""                                         2

# ---------------------------------------------------------------------------
# `--url <value>` mode (#1899)
#
# Why the mode exists: a caller that both PARSES a remote URL (for owner/repo)
# and CLASSIFIES it (for the host) must not read `git remote get-url origin`
# twice. Two independent reads can diverge — a credential helper, an `insteadOf`
# rewrite, or an interleaved `git remote set-url` between them — and the
# owner/repo the caller then hands to `gh api repos/<owner>/<repo>` under the
# user's token would be one this classifier never approved. `--url` takes the
# bytes the caller already holds, making parsed and classified provably
# identical. bin/github-issues/lib/origin-repo.sh is the first consumer.
#
# Two claims are asserted below, and they are separate concerns:
#   (a) PARITY — for the same URL, `--url` returns exactly what directory mode
#       returns. The rows are the URL/rc pairs from the table above, so a future
#       change to the host rules cannot land in one mode only (CPR-ORTH).
#   (b) NO GIT READ — `--url` classifies the argument and nothing else. Running
#       it inside a repo whose real origin classifies the OTHER way is what makes
#       that observable; a residual `git remote get-url origin` would answer with
#       the repo's URL and flip the rc.
# ---------------------------------------------------------------------------

# run_helper_url <dir-to-run-from> <arg...> -> prints exit code
run_helper_url() {
    local dir="$1"; shift
    (
        cd "$dir"
        run_with_timeout bash "$HELPER" "$@" >/dev/null 2>&1
        echo $?
    )
}

# A repo whose origin is github.com — deliberately the OPPOSITE classification
# from most rows below, so any leftover git read is visible as a wrong rc rather
# than as a silent agreement.
URL_MODE_CWD=$(make_repo "u00" "https://github.com/cwd-owner/cwd-repo.git")

while IFS='|' read -r case_name url_value expected; do
    [ -z "${case_name// /}" ] && continue
    case "$case_name" in \#*) continue ;; esac
    case_name="$(echo "$case_name" | xargs)"
    url_value="$(echo "$url_value" | xargs)"
    expected="$(echo "$expected" | xargs)"

    rc=$(run_helper_url "$URL_MODE_CWD" --url "$url_value")
    if [ "$rc" = "$expected" ]; then
        pass "url_mode/$case_name"
    else
        fail "url_mode/$case_name (expected=$expected, got=$rc, url='$url_value')"
    fi
# The single quotes inside some URLs below are LOAD-BEARING, for the same reason
# as the `""` splices further up: every row is normalised through `xargs`, which
# removes them, so the value actually classified is byte-identical to the
# unquoted form — while the source line carries no contiguous `<local>@<domain>`
# run for bin/scan-outbound.sh's email pattern to false-positive on.
done <<'TABLE'
# case                  | url value                                    | expected rc
ssh_github_dotgit       | git@github.com:owner/repo.git                | 0
https_github_dotgit     | https://github.com/owner/repo.git            | 0
https_github_no_dotgit  | https://github.com/owner/repo                | 0
ssh_github_no_dotgit    | git@github.com:owner/repo                    | 0
https_github_userinfo   | https://'user'@github.com/owner/repo.git     | 0
ssh_gitlab              | git@'gitlab.com':owner/repo.git              | 1
https_bitbucket         | https://bitbucket.org/owner/repo.git         | 1
ssh_internal_host       | git@'example.internal':owner/repo.git        | 1
ssh_mixed_case          | git@'GitHub.COM':owner/repo.git              | 0
https_github_port443    | https://github.com:443/owner/repo.git        | 0
ssh_subdomain_evil      | git@github.com.evil.com:owner/repo.git       | 1
https_subdomain_evil    | https://github.com.evil.com/owner/repo.git   | 1
ssh_prefix_notgithub    | git@'notgithub.com':owner/repo.git           | 1
# Unparsable shapes are "unknown", not "non-GitHub": rc 2 tells the caller it
# learned nothing, so it can fail closed rather than treat the URL as a
# confirmed third-party host.
bare_path_no_host       | /srv/git/owner/repo.git                      | 2
garbage                 | not-a-url-at-all                             | 2
TABLE

# The NO-GIT-READ claim, stated directly. The cwd repo's origin is github.com;
# these arguments are not. A residual `git remote get-url origin` would answer
# github.com and return 0.
rc=$(run_helper_url "$URL_MODE_CWD" --url "https://gitlab.com/owner/repo.git")
if [ "$rc" = "1" ]; then
    pass "url_mode/argument_wins_over_cwd_origin"
else
    fail "url_mode/argument_wins_over_cwd_origin (expected=1, got=$rc)"
fi

# The mirror: a github.com argument inside a NON-github checkout still classifies
# from the argument. Together the two rule out "the cwd happened to agree".
URL_MODE_CWD_NG=$(make_repo "u01" "https://gitlab.com/cwd-owner/cwd-repo.git")
rc=$(run_helper_url "$URL_MODE_CWD_NG" --url "https://github.com/owner/repo.git")
if [ "$rc" = "0" ]; then
    pass "url_mode/argument_wins_over_non_github_cwd_origin"
else
    fail "url_mode/argument_wins_over_non_github_cwd_origin (expected=0, got=$rc)"
fi

# `--url` with an EMPTY value and `--url` with no value at all are both
# indistinguishable from "no origin" — rc 2 (unknown), never 0 and never a crash.
# The caller (origin-repo.sh) turns a non-zero here into its own fail-closed
# return, so an accidental rc 0 on an empty URL would approve a host nobody named.
rc=$(run_helper_url "$URL_MODE_CWD" --url "")
if [ "$rc" = "2" ]; then pass "url_mode/empty_value_is_rc2"
else fail "url_mode/empty_value_is_rc2 (expected=2, got=$rc)"; fi

rc=$(run_helper_url "$URL_MODE_CWD" --url)
if [ "$rc" = "2" ]; then pass "url_mode/missing_value_is_rc2"
else fail "url_mode/missing_value_is_rc2 (expected=2, got=$rc)"; fi

# Directory mode is UNCHANGED by the addition: an explicit <repo-dir> argument
# still reads that repo's origin. The 14 rows above cover cwd-default dispatch;
# this covers the positional-argument form, which `--url` sits beside in the
# same argument slot and could have shadowed.
rc=$(run_helper_url "$TMPDIR_BASE" "$URL_MODE_CWD")
if [ "$rc" = "0" ]; then pass "dir_mode/positional_dir_still_reads_that_repo"
else fail "dir_mode/positional_dir_still_reads_that_repo (expected=0, got=$rc)"; fi

rc=$(run_helper_url "$TMPDIR_BASE" "$URL_MODE_CWD_NG")
if [ "$rc" = "1" ]; then pass "dir_mode/positional_dir_non_github"
else fail "dir_mode/positional_dir_non_github (expected=1, got=$rc)"; fi

# ---------------------------------------------------------------------------
echo
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed."
else
    echo "$ERRORS test(s) failed."
fi
exit "$ERRORS"
