# ===========================================================================
# Tests: hooks/lib/is-private-repo.js, hooks/lib/parse-remote-url.js
# Tags: scan, filter, outbound, hook, tests, scope:common
#
# Unit tests: pure remote-URL parsing helpers re-exported by is-private-repo.js
# ===========================================================================

echo "=== Unit: extractRepoId ==="

run_extract() {
    node -e "
const { extractRepoId } = require('$LIB');
console.log(extractRepoId(process.argv[1]) || 'null');
" "$1"
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
console.log(extractHost(process.argv[1]) || 'null');
" "$1"
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
console.log(extractRepoDirFromCommand(process.argv[1]) || 'null');
" "$1"
}

result=$(run_extract_dir "git -C /some/path commit -m msg")
if [ "$result" = "/some/path" ]; then pass "git -C path extraction"
else fail "git -C path extraction — got: $result"; fi

result=$(run_extract_dir "git commit -m msg")
if [ "$result" = "null" ]; then pass "no -C flag"
else fail "no -C flag — got: $result"; fi
