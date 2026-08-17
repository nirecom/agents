#!/usr/bin/env bash
# tests/unit-is-github-dotcom-remote.sh
# Tests: bin/is-github-dotcom-remote
# Tags: bin, url-classification, table-driven, scope:common, pwsh-not-required, TL2
#
# A URL classifier built from two regexes, so it is governed by
# skills/_shared/test-design/parser-regex-tests.md: table-driven, one named row per
# input, expected exit code pinned per row.

set -u

# A whole file rather than more rows inside the #1532 guard suite: the input domain is
# a property of THIS command, not of the guard envelope, and bin/select-tests.sh Tier 1
# selects on the filename stem -- `is-github-dotcom-remote` is in this filename, so an
# edit to the command selects these rows too.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$REPO_ROOT/bin/is-github-dotcom-remote"

# The three exit codes are a contract: 0 = github.com, 1 = another host, 2 = unknown
# (fail-open). 2 is the one worth stating -- callers read it as "cannot tell", so a
# malformed or absent remote must never be classified as 1 ("definitely not GitHub").
PASS=0
FAIL=0

# EXECUTED-ROW BUDGET (review round 3, codex C4). A `while IFS='|' read -r` loop whose
# heredoc delimiter drifted, or whose table was emptied, reports zero assertions and
# still exits 0 -- indistinguishable from "everything passed" in a file that only counts
# failures. Each table increments its own counter and the totals are asserted below
# against the exact row count. A row deliberately added or removed must be re-budgeted
# here on purpose, which is the point.
U_ROWS=0
U_ROWS_EXPECTED=41
R_ROWS=0
R_ROWS_EXPECTED=6

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name -- want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}

if [ ! -f "$SUBJECT" ]; then
    echo "FAIL: PRECONDITION -- $SUBJECT does not exist"
    echo ""
    echo "Total: 0 passed, 1 failed"
    exit 1
fi

TESTTMP="$(mktemp -d "${TMPDIR:-/tmp}/unit-is-github-dotcom-remote.XXXXXX")" || {
    echo "FATAL: mktemp -d failed" >&2
    exit 2
}
trap 'cd / 2>/dev/null; rm -rf "$TESTTMP"' EXIT
cd "$TESTTMP" || exit 2

# ---- Table 1: --url classification ------------------------------------------
# The URL never reaches a git command on this path, so no fixture repo is needed and
# every row is a pure function of the two regexes.
run_url() { # <url>
    bash "$SUBJECT" --url "$1" >/dev/null 2>&1
    echo $?
}

echo "=== U: --url classification ==="
while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    # Only the surrounding padding is trimmed: a URL has no internal spaces, but
    # stripping ALL whitespace would also hide a row that deliberately tested one.
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    # `@` is written as `%AT%` in the table so the outbound private-info scanner does not read the fixture URLs as email addresses.
    input="${input//%AT%/@}"
    U_ROWS=$((U_ROWS + 1))
    assert_eq "U[$name]" "$want" "$(run_url "$input")"
done <<'TABLE'
# --- github.com, every shape a real remote takes -> 0
https-github            | https://github.com/owner/repo.git         | 0
https-github-no-dotgit  | https://github.com/owner/repo             | 0
https-github-userinfo   | https://user%AT%github.com/owner/repo.git | 0
https-github-token      | https://x-token:pw%AT%github.com/o/r.git  | 0
http-github             | http://github.com/owner/repo.git          | 0
ssh-url-github          | ssh://git%AT%github.com/owner/repo.git    | 0
ssh-url-github-port     | ssh://git%AT%github.com:22/owner/repo.git | 0
git-proto-github        | git://github.com/owner/repo.git           | 0
scp-github              | git%AT%github.com:owner/repo.git          | 0
scp-github-no-dotgit    | git%AT%github.com:owner/repo              | 0
scp-github-nested-path  | git%AT%github.com:owner/group/repo.git    | 0
# --- case-insensitivity is part of the contract: DNS hosts are case-folded
https-github-upper      | https://GITHUB.COM/owner/repo.git         | 0
https-github-mixed      | https://GitHub.Com/owner/repo.git         | 0
scp-github-upper        | git%AT%GITHUB.COM:owner/repo.git          | 0
ssh-url-github-mixed    | ssh://git%AT%GitHub.com/owner/repo.git    | 0
# --- other hosts -> 1
ghe-https               | https://github.example.com/o/r.git        | 1
ghe-scp                 | git%AT%github.example.com:o/r.git         | 1
ghe-bare-host           | https://ghe/owner/repo.git                | 1
gitlab-https            | https://gitlab.com/owner/repo.git         | 1
gitlab-scp              | git%AT%gitlab.com:owner/repo.git          | 1
bitbucket-scp           | git%AT%bitbucket.org:owner/repo.git       | 1
github-io-pages         | https://owner.github.io/repo.git          | 1
# --- look-alikes that must NOT be read as github.com
lookalike-suffix-host   | https://github.com.evil.example/o/r       | 1
lookalike-prefix-host   | https://notgithub.com/owner/repo.git      | 1
lookalike-hyphen-host   | https://my-github.com/owner/repo.git      | 1
lookalike-in-path       | https://gitlab.com/github.com/repo.git    | 1
lookalike-in-path-evil  | https://evil.example/github.com/r.git     | 1
lookalike-in-userinfo   | https://github.com%AT%gitlab.com/o/r.git  | 1
# --- unclassifiable -> 2 (fail-open, never 1)
# A bare host with no scheme and no `user@` matches NEITHER regex. It reaches the else
# branch, so `github.com` on its own is 2, not 0: this classifier reads remote URLs, and
# a hostname alone is not one. Recorded because "must not be read as github.com" is
# satisfied here by 2 rather than by 1.
bare-host-no-scheme     | github.com                                | 2
bare-host-with-path     | github.com/owner/repo.git                 | 2
# --- malformed URLs: no host to compare -> 2, never a confident 1
malformed-scheme-only   | https://                                  | 2
malformed-empty-host    | https:///owner/repo.git                   | 2
malformed-scp-empty-host| git%AT%:owner/repo.git                    | 2
malformed-at-no-colon   | git%AT%github.com                         | 2
malformed-no-scheme-name| ://github.com/owner/repo.git              | 2
# file:// is host-less by construction, so it lands here rather than in the "other
# host" group: there is no host to compare, and 2 says exactly that.
file-url                | file:///srv/mirrors/repo.git              | 2
empty-url               |                                           | 2
absolute-local-path     | /srv/git/repo                             | 2
relative-local-path     | ../sibling/repo                           | 2
windows-drive-path      | C:/git/agents                             | 2
bare-name               | repo                                      | 2
TABLE

# ---- Table 2: repository-directory classification ---------------------------
# The default path reads `git remote get-url origin`. A throwaway repo is created in
# the temp dir and its origin rewritten per row with `git remote set-url` -- this
# checkout's own remote is never read and never touched.
FIXTURE="$TESTTMP/fixture-repo"
mkdir -p "$FIXTURE"
git -C "$FIXTURE" init -q >/dev/null 2>&1
git -C "$FIXTURE" config core.hooksPath /dev/null >/dev/null 2>&1

echo "=== R: repository-directory classification ==="
if [ ! -d "$FIXTURE/.git" ]; then
    echo "FAIL: R[precondition] -- the throwaway fixture repo could not be created, so the repo-dir path is unproven"
    FAIL=$((FAIL + 1))
else
    # No origin yet: "cannot tell", not "not GitHub".
    bash "$SUBJECT" "$FIXTURE" >/dev/null 2>&1
    assert_eq "R[no-origin-remote]" "2" "$?"
    git -C "$FIXTURE" remote add origin https://example.com/placeholder.git >/dev/null 2>&1

    while IFS='|' read -r name input want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        input="${input#"${input%%[![:space:]]*}"}"
        input="${input%"${input##*[![:space:]]}"}"
        # `@` is written as `%AT%` in the table so the outbound private-info scanner does not read the fixture URLs as email addresses.
        input="${input//%AT%/@}"
        R_ROWS=$((R_ROWS + 1))
        git -C "$FIXTURE" remote set-url origin "$input" >/dev/null 2>&1
        bash "$SUBJECT" "$FIXTURE" >/dev/null 2>&1
        assert_eq "R[$name]" "$want" "$?"
    done <<'TABLE'
origin-github-https  | https://github.com/owner/repo.git  | 0
origin-github-scp    | git%AT%github.com:owner/repo.git   | 0
origin-github-upper  | https://GITHUB.COM/owner/repo.git  | 0
origin-ghe           | https://github.example.com/o/r.git | 1
origin-gitlab        | https://gitlab.com/owner/repo.git  | 1
origin-local-path    | /srv/mirrors/repo.git              | 2
TABLE

    # A directory that is not a repo, and a path that does not exist: both "unknown".
    # Classifying either as 1 would let a caller act on a false negative.
    mkdir -p "$TESTTMP/plain-dir"
    bash "$SUBJECT" "$TESTTMP/plain-dir" >/dev/null 2>&1
    assert_eq "R[not-a-git-repo]" "2" "$?"
    bash "$SUBJECT" "$TESTTMP/no-such-directory" >/dev/null 2>&1
    assert_eq "R[nonexistent-directory]" "2" "$?"
fi

# ---- Argument-form edge cases -----------------------------------------------
# `--url` with nothing after it is indistinguishable from "no origin" -> 2. Asserted
# here because the table above always supplies a second argument.
bash "$SUBJECT" --url >/dev/null 2>&1
assert_eq "E[url-flag-without-value]" "2" "$?"

# Every classification is silent: callers branch on the exit code alone, and a stray
# stdout byte would corrupt a $( ) caller that wrapped this command.
out="$(bash "$SUBJECT" --url https://github.com/owner/repo.git 2>/dev/null)"
assert_eq "E[stdout-is-empty-on-match]" "" "$out"
out="$(bash "$SUBJECT" --url https://gitlab.com/owner/repo.git 2>/dev/null)"
assert_eq "E[stdout-is-empty-on-non-match]" "" "$out"

# Whitespace-only cannot live in the table: the loop trims surrounding padding, so such a
# row would arrive as the empty string and silently duplicate `empty-url`. It is a real
# shape -- `git remote get-url` on a mangled config can yield it -- and it must be 2.
bash "$SUBJECT" --url "   " >/dev/null 2>&1
assert_eq "E[whitespace-only-url]" "2" "$?"
bash "$SUBJECT" --url "$(printf '\t')" >/dev/null 2>&1
assert_eq "E[tab-only-url]" "2" "$?"

# ---- executed-row budget ----------------------------------------------------
assert_eq "B[url-table-rows-executed]" "$U_ROWS_EXPECTED" "$U_ROWS"
assert_eq "B[repo-table-rows-executed]" "$R_ROWS_EXPECTED" "$R_ROWS"

echo ""
echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
