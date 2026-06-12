#!/bin/bash
# Tests: hooks/lib/sentinel-patterns.js, hooks/workflow-gate/review-tests-evidence.js
# Tags: workflow, sentinel, ssot, review-tests, token
#
# SSOT tests for the review_tests sentinel family (issue #833).
#
# Verifies the regex constants that workflow-mark.js and workflow-gate.js
# share for recognizing the new REVIEW_TESTS_COMPLETE / REVIEW_TESTS_WARNINGS
# sentinels, plus the stale-token computation used by the gate's
# anti-bypass guard.
#
# Pre-implementation expectation: all tests FAIL until write-code lands.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SENTINEL_PATTERNS="$AGENTS_DIR/hooks/lib/sentinel-patterns.js"
REVIEW_TESTS_EVIDENCE="$AGENTS_DIR/hooks/workflow-gate/review-tests-evidence.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# Windows-compatible tmpdir
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/rtssot.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Helpers — invoke a single regex via node, assert match/no-match.
# Loads sentinel-patterns.js with `require()` and tests the named export.
# ---------------------------------------------------------------------------
assert_regex_match() {
    local desc="$1" regex_name="$2" command="$3"
    local result
    result=$(run_with_timeout node -e "
        try {
            const sp = require(process.argv[1]);
            const re = sp[process.argv[2]];
            if (!re) { process.stdout.write('NOT_EXPORTED'); process.exit(0); }
            if (!(re instanceof RegExp)) { process.stdout.write('NOT_REGEX'); process.exit(0); }
            process.stdout.write(re.test(process.argv[3]) ? 'MATCH' : 'NO_MATCH');
        } catch (e) {
            process.stdout.write('ERROR: ' + e.message);
        }
    " -- "$SENTINEL_PATTERNS" "$regex_name" "$command" 2>/dev/null || echo "ERROR")
    if [ "$result" = "MATCH" ]; then
        pass "$desc"
    else
        fail "$desc — expected MATCH for /$regex_name/ on '$command', got: $result"
    fi
}

assert_regex_no_match() {
    local desc="$1" regex_name="$2" command="$3"
    local result
    result=$(run_with_timeout node -e "
        try {
            const sp = require(process.argv[1]);
            const re = sp[process.argv[2]];
            if (!re) { process.stdout.write('NOT_EXPORTED'); process.exit(0); }
            if (!(re instanceof RegExp)) { process.stdout.write('NOT_REGEX'); process.exit(0); }
            process.stdout.write(re.test(process.argv[3]) ? 'MATCH' : 'NO_MATCH');
        } catch (e) {
            process.stdout.write('ERROR: ' + e.message);
        }
    " -- "$SENTINEL_PATTERNS" "$regex_name" "$command" 2>/dev/null || echo "ERROR")
    if [ "$result" = "NO_MATCH" ]; then
        pass "$desc"
    else
        fail "$desc — expected NO_MATCH for /$regex_name/ on '$command', got: $result"
    fi
}

assert_isSentinel() {
    local desc="$1" command="$2" expected="$3"
    local result
    result=$(run_with_timeout node -e "
        try {
            const sp = require(process.argv[1]);
            process.stdout.write(sp.isSentinel(process.argv[2]) ? 'YES' : 'NO');
        } catch (e) {
            process.stdout.write('ERROR: ' + e.message);
        }
    " -- "$SENTINEL_PATTERNS" "$command" 2>/dev/null || echo "ERROR")
    if [ "$result" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc — expected $expected from isSentinel('$command'), got: $result"
    fi
}

# ---------------------------------------------------------------------------
# Section 1 — Sentinel regex SSOT (8 cases)
# ---------------------------------------------------------------------------

echo "=== Section 1: review_tests sentinel regex SSOT ==="

# T1: REVIEW_TESTS_COMPLETE_RE_DQ — happy form
assert_regex_match "T1. REVIEW_TESTS_COMPLETE_RE_DQ accepts canonical form" \
    "REVIEW_TESTS_COMPLETE_RE_DQ" \
    'echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE: token=abc123>>"'

# T2: REVIEW_TESTS_COMPLETE_RE_DQ rejects bare form (no token payload)
assert_regex_no_match "T2. REVIEW_TESTS_COMPLETE_RE_DQ rejects bare (no payload)" \
    "REVIEW_TESTS_COMPLETE_RE_DQ" \
    'echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE>>"'

# T3: REVIEW_TESTS_WARNINGS_RE_DQ — happy form with summary
assert_regex_match "T3. REVIEW_TESTS_WARNINGS_RE_DQ accepts canonical form (token + warnings summary)" \
    "REVIEW_TESTS_WARNINGS_RE_DQ" \
    'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS: token=abc123 warnings=2 INFO=1>>"'

# T4: REVIEW_TESTS_WARNINGS_LOOKSLIKE_RE — bare form falls through as "looks like"
# (used for advisory rejection of malformed warnings sentinels)
assert_regex_match "T4. REVIEW_TESTS_WARNINGS_LOOKSLIKE_RE catches bare form for advisory rejection" \
    "REVIEW_TESTS_WARNINGS_LOOKSLIKE_RE" \
    'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS>>"'

# T5: isSentinel() recognises COMPLETE form
assert_isSentinel "T5. isSentinel() accepts REVIEW_TESTS_COMPLETE with token" \
    'echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE: token=abc123>>"' \
    "YES"

# T6: isSentinel() recognises WARNINGS form
assert_isSentinel "T6. isSentinel() accepts REVIEW_TESTS_WARNINGS with token + summary" \
    'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS: token=abc123 warnings=2>>"' \
    "YES"

# T7: isSentinel() recognises LOOKSLIKE form so workflow-gate can advise rather than silently pass
assert_isSentinel "T7. isSentinel() recognises bare WARNINGS form (LOOKSLIKE fallthrough)" \
    'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS>>"' \
    "YES"

# T8: REVIEW_TESTS_COMPLETE strict DQ rejects single-quoted form
# (Per sentinel-patterns.js convention, only MARK_STEP is SQ-tolerant; others are DQ-only.)
assert_regex_no_match "T8. REVIEW_TESTS_COMPLETE_RE_DQ rejects single-quoted form" \
    "REVIEW_TESTS_COMPLETE_RE_DQ" \
    "echo '<<WORKFLOW_REVIEW_TESTS_COMPLETE: token=abc123>>'"

# T8b: REVIEW_TESTS_COMPLETE_LOOKSLIKE_RE — bare form matches (symmetric with WARNINGS LOOKSLIKE)
assert_regex_match "T8b. REVIEW_TESTS_COMPLETE_LOOKSLIKE_RE catches bare form for advisory rejection" \
    "REVIEW_TESTS_COMPLETE_LOOKSLIKE_RE" \
    'echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE>>"'

# T8c: isSentinel() recognises COMPLETE lookslike form (advisory path)
assert_isSentinel "T8c. isSentinel() recognises bare COMPLETE form (LOOKSLIKE fallthrough)" \
    'echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE>>"' \
    "YES"

# ---------------------------------------------------------------------------
# Section 2 — Staged-tests token computation
# (computeStagedTestsToken(repoDir) → SHA hash | null)
# ---------------------------------------------------------------------------

echo ""
echo "=== Section 2: computeStagedTestsToken evidence ==="

# Build a tiny throwaway git repo with tests/ staged.
setup_repo_with_staged_tests() {
    local repo="$1"
    mkdir -p "$repo/tests"
    (
        cd "$repo"
        git init -q
        git config user.email test@example.com
        git config user.name Test
        echo "initial" > README.md
        # core.hooksPath="" — bypass global enforce-worktree hook
        git -c core.hooksPath="" add README.md
        git -c core.hooksPath="" commit -q -m initial
    )
    printf 'test content 1\n' > "$repo/tests/feature-a.sh"
    printf 'test content 2\n' > "$repo/tests/feature-b.sh"
    git -C "$repo" add tests/feature-a.sh tests/feature-b.sh
}

# Helper: call computeStagedTestsToken(repoDir) via node.
call_compute_token() {
    local repo="$1"
    run_with_timeout node -e "
        try {
            const m = require(process.argv[1]);
            if (typeof m.computeStagedTestsToken !== 'function') {
                process.stdout.write('NOT_IMPLEMENTED');
                process.exit(0);
            }
            const out = m.computeStagedTestsToken(process.argv[2]);
            process.stdout.write(out == null ? 'NULL' : String(out));
        } catch (e) {
            process.stdout.write('ERROR: ' + e.message);
        }
    " -- "$REVIEW_TESTS_EVIDENCE" "$repo" 2>/dev/null || echo "ERROR"
}

# T9: Same staged content → same token (deterministic)
REPO_A="$TMPDIR_BASE/repo-a"
mkdir -p "$REPO_A"
setup_repo_with_staged_tests "$REPO_A"
TOKEN_A1=$(call_compute_token "$REPO_A")
TOKEN_A2=$(call_compute_token "$REPO_A")
if [ "$TOKEN_A1" = "$TOKEN_A2" ] && [ "$TOKEN_A1" != "NULL" ] && [ "$TOKEN_A1" != "ERROR" ] && [ "$TOKEN_A1" != "NOT_IMPLEMENTED" ]; then
    pass "T9. computeStagedTestsToken is deterministic for unchanged staged content"
else
    fail "T9. expected stable non-null token; got first=$TOKEN_A1 second=$TOKEN_A2"
fi

# T10: Modified staged content → different token (stale-token detection foundation)
printf 'test content 1 modified\n' > "$REPO_A/tests/feature-a.sh"
git -C "$REPO_A" add tests/feature-a.sh
TOKEN_A3=$(call_compute_token "$REPO_A")
if [ "$TOKEN_A3" != "$TOKEN_A1" ] && [ "$TOKEN_A3" != "NULL" ] && [ "$TOKEN_A3" != "ERROR" ] && [ "$TOKEN_A3" != "NOT_IMPLEMENTED" ]; then
    pass "T10. computeStagedTestsToken changes when staged tests/ content changes (stale-token detection)"
else
    fail "T10. expected new non-null token differing from $TOKEN_A1, got: $TOKEN_A3"
fi

# T11: No tests/ staged → null
REPO_B="$TMPDIR_BASE/repo-b"
mkdir -p "$REPO_B"
(
    cd "$REPO_B"
    git init -q
    git config user.email test@example.com
    git config user.name Test
    echo "initial" > README.md
    git -c core.hooksPath="" add README.md
    git -c core.hooksPath="" commit -q -m initial
)
# Stage a non-tests/ file
echo "source code" > "$REPO_B/src.js"
mkdir -p "$REPO_B/src"
echo "module code" > "$REPO_B/src/index.js"
git -C "$REPO_B" add src.js src/index.js
TOKEN_B=$(call_compute_token "$REPO_B")
if [ "$TOKEN_B" = "NULL" ]; then
    pass "T11. computeStagedTestsToken returns null when no tests/ files staged"
else
    fail "T11. expected NULL when no tests/ staged, got: $TOKEN_B"
fi

# T12: Non-git path → null (fail-open)
NON_GIT="$TMPDIR_BASE/non-git"
mkdir -p "$NON_GIT/tests"
echo "x" > "$NON_GIT/tests/some.sh"
TOKEN_NON_GIT=$(call_compute_token "$NON_GIT")
if [ "$TOKEN_NON_GIT" = "NULL" ]; then
    pass "T12. computeStagedTestsToken returns null for non-git directory (fail-open)"
else
    fail "T12. expected NULL for non-git dir, got: $TOKEN_NON_GIT"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    exit 1
fi
