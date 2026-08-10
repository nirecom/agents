# ===========================================================================
# Tests: hooks/lib/is-private-repo.js, hooks/lib/parse-remote-url.js
# Tags: scan, filter, outbound, hook, tests, scope:common
#
# isPrivateRepo() × parseOriginOwnerRepo() failure codes (#1899)
#
# Background: isPrivateRepo() collapses every parse failure into ONE boolean —
#   return parsed.code === "non-github-host";
# so `non-github-host` fails CLOSED (treated as private) while every other
# failure code fails OPEN (treated as public). Existing coverage reaches the
# fail-open result only through gh throwing, a missing remote, or a bad path —
# never through a parse failure on a well-formed github.com URL. An edit that
# inverted which codes fail open would pass all of those silently.
#
# Two properties are asserted per case, because either alone is satisfiable by
# a wrong implementation:
#   1. the returned value is false (fail-open), and
#   2. `gh api` was never invoked — there is no validated repo identity to ask
#      about, and asking anyway would query an unrelated repository.
# The recording mock answers "true" (private), so any stray gh call would flip
# property 1 as well; the two assertions are not redundant restatements.
# ===========================================================================

echo ""
echo "=== Unit: parse-failure fail-open (no gh call) ==="

# want=false AND gh call count 0
assert_fail_open_without_gh() {
    local desc="$1" url="$2"
    local repo result calls
    setup_mock_gh_recording
    repo=$(setup_repo_with_origin "$url")
    result=$(run_is_private_repo "$repo")
    calls=$(gh_call_count)
    if [ "$result" = "false" ] && [ "$calls" = "0" ]; then
        pass "$desc — returned=false, gh calls=0"
    else
        fail "$desc — want returned=false/gh-calls=0, got returned=$result/gh-calls=$calls"
    fi
}

# --- Positive control -------------------------------------------------------
# Proves the recorder is wired up: a parseable github.com origin MUST reach gh
# and MUST return the mock's "true". Without this, an always-empty call log
# would make every assertion above vacuously green.
setup_mock_gh_recording
REPO_OK=$(setup_repo_with_origin "git@github.com:testowner/testrepo.git")
result=$(run_is_private_repo "$REPO_OK")
calls=$(gh_call_count)
if [ "$result" = "true" ] && [ "$calls" -ge 1 ]; then
    pass "control: parseable github.com origin — returned=true, gh calls=$calls"
else
    fail "control: parseable github.com origin — want returned=true/gh-calls>=1, got returned=$result/gh-calls=$calls"
fi

# --- unparsable-owner-repo --------------------------------------------------
# Host is exactly github.com in each case; only the owner/repo path is rejected.
# Charsets come from parse-remote-url.js: owner /^[A-Za-z0-9][A-Za-z0-9-]{0,38}$/
# (no underscores, no dots), repo /^[A-Za-z0-9._-]{1,100}$/ with "."/".." banned.

# Owner carries an underscore — outside the GitHub login charset.
assert_fail_open_without_gh \
    "unparsable-owner-repo: SSH origin with underscore in owner" \
    "git@github.com:own_er/testrepo.git"

# Deeper path leaves "team/testrepo" as the repo candidate; the slash is
# outside the repo charset.
assert_fail_open_without_gh \
    "unparsable-owner-repo: HTTPS origin with a three-segment path" \
    "https://github.com/testowner/team/testrepo.git"

# Owner-only path: no separator, so both owner and repo resolve empty.
assert_fail_open_without_gh \
    "unparsable-owner-repo: HTTPS origin with owner but no repo" \
    "https://github.com/testowner"

# Dot-segment repo name — the traversal shape the charset exists to reject.
assert_fail_open_without_gh \
    "unparsable-owner-repo: origin whose repo segment is '..'" \
    "git@github.com:testowner/.."

# --- unparsable-host --------------------------------------------------------
# Independently reachable: extractHost() returns null for any remote URL that is
# neither <scheme>://... nor user@host:path, which a local bare-repo remote is.
# That lands on the unparsable-host branch BEFORE the github.com comparison, so
# it is a distinct arm from both non-github-host and unparsable-owner-repo.

assert_fail_open_without_gh \
    "unparsable-host: absolute local-path origin (no host in URL)" \
    "/srv/git/mirror.git"

assert_fail_open_without_gh \
    "unparsable-host: relative local-path origin (no host in URL)" \
    "../mirror.git"
