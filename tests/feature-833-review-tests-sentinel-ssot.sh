#!/bin/bash
# Tests: hooks/lib/sentinel-patterns.js, hooks/workflow-gate/review-tests-evidence.js
# Tags: workflow, sentinel, ssot, review-tests, token, scope:issue-specific
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
# Section 3 — WARNINGS_ACCEPTED sentinel table-driven tests (cases 12-17)
# Issue #1207 — new sentinel for clearing warnings after user review.
# DQ strict form: echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: reason>>"
# LOOKSLIKE form: <<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED...>> (no strict DQ)
#
# EXPECTED: cases 12-17 FAIL until REVIEW_TESTS_WARNINGS_ACCEPTED_RE_DQ and
#           REVIEW_TESTS_WARNINGS_ACCEPTED_LOOKSLIKE_RE are added to
#           hooks/lib/sentinel-patterns.js (and isSentinel/isStrictSentinel updated).
# ---------------------------------------------------------------------------

echo ""
echo "=== Section 3: REVIEW_TESTS_WARNINGS_ACCEPTED sentinel (table-driven) ==="

# Evaluates a sentinel command for the named regex and returns MATCH or NO_MATCH.
eval_sentinel_regex() {
    local regex_name="$1" cmd="$2"
    run_with_timeout node -e "
        try {
            const sp = require(process.argv[1]);
            const re = sp[process.argv[2]];
            if (!re) { process.stdout.write('NOT_EXPORTED'); process.exit(0); }
            if (!(re instanceof RegExp)) { process.stdout.write('NOT_REGEX'); process.exit(0); }
            process.stdout.write(re.test(process.argv[3]) ? 'MATCH' : 'NO_MATCH');
        } catch (e) { process.stdout.write('ERROR:' + e.message); }
    " -- "$SENTINEL_PATTERNS" "$regex_name" "$cmd" 2>/dev/null || echo "ERROR"
}

eval_is_sentinel() {
    local cmd="$1"
    run_with_timeout node -e "
        try {
            const sp = require(process.argv[1]);
            process.stdout.write(sp.isSentinel(process.argv[2]) ? 'YES' : 'NO');
        } catch (e) { process.stdout.write('ERROR:' + e.message); }
    " -- "$SENTINEL_PATTERNS" "$cmd" 2>/dev/null || echo "ERROR"
}

eval_is_strict() {
    local cmd="$1"
    run_with_timeout node -e "
        try {
            const sp = require(process.argv[1]);
            if (typeof sp.isStrictSentinel !== 'function') {
                process.stdout.write('NOT_EXPORTED'); process.exit(0);
            }
            process.stdout.write(sp.isStrictSentinel(process.argv[2]) ? 'YES' : 'NO');
        } catch (e) { process.stdout.write('ERROR:' + e.message); }
    " -- "$SENTINEL_PATTERNS" "$cmd" 2>/dev/null || echo "ERROR"
}

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS: $name"; PASS=$((PASS + 1))
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1))
    fi
}

# Table-driven: name | input command | want (MATCH or NO_MATCH)
# Tests REVIEW_TESTS_WARNINGS_ACCEPTED_RE_DQ (strict double-quote form).
DQ_RE="REVIEW_TESTS_WARNINGS_ACCEPTED_RE_DQ"

while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    input="${input#"${input%%[! ]*}"}"
    input="${input%"${input##*[! ]}"}"
    got=$(eval_sentinel_regex "$DQ_RE" "$input")
    assert_eq "T${name}.DQ_RE" "$want" "$got"
done <<'DQ_TABLE'
12  | echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: all warnings reviewed>>" | MATCH
13b | echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED>>"                         | NO_MATCH
14  | echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: >>"                       | NO_MATCH
15  | echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: reason>>ignored"          | NO_MATCH
16a | echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: r>>" && rm -f /tmp/x      | NO_MATCH
DQ_TABLE

# Table-driven: LOOKSLIKE form (broader match for advisory rejection).
LL_RE="REVIEW_TESTS_WARNINGS_ACCEPTED_LOOKSLIKE_RE"

while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    input="${input#"${input%%[! ]*}"}"
    input="${input%"${input##*[! ]}"}"
    got=$(eval_sentinel_regex "$LL_RE" "$input")
    assert_eq "T${name}.LL_RE" "$want" "$got"
done <<'LL_TABLE'
13  | echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED>>"          | MATCH
14b | echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: reason>>"  | MATCH
LL_TABLE

# Case 12 isSentinel — DQ form accepted by isSentinel().
cmd12='echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: all warnings reviewed>>"'
got12_is="$(eval_is_sentinel "$cmd12")"
assert_eq "T12.isSentinel" "YES" "$got12_is"

# Case 12 isStrictSentinel — DQ form accepted by isStrictSentinel().
got12_strict="$(eval_is_strict "$cmd12")"
assert_eq "T12.isStrictSentinel" "YES" "$got12_strict"

# Case 13 isSentinel — bare form (no reason) IS recognized by isSentinel (LOOKSLIKE fallthrough).
cmd13='echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED>>"'
got13_is="$(eval_is_sentinel "$cmd13")"
assert_eq "T13.isSentinel(bare-lookslike)" "YES" "$got13_is"

# Case 13 isStrictSentinel — bare form NOT a strict sentinel.
got13_strict="$(eval_is_strict "$cmd13")"
assert_eq "T13.isStrictSentinel(bare-NOT-strict)" "NO" "$got13_strict"

# Case 16 — reason containing > must NOT be a strict sentinel (reason text contains >).
cmd15='echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: r>x>>"'
got15_strict="$(eval_is_strict "$cmd15")"
assert_eq "T15.isStrictSentinel(reason-with->)" "NO" "$got15_strict"

# Case 17 — mutation probe: bin/mutation-probe.sh verifies the regex is not trivially green.
#
# SKIPPED-Because: sentinel-patterns.js uses multi-line const forms:
#   const REVIEW_TESTS_WARNINGS_ACCEPTED_RE_DQ =
#     /^echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: ([^>]+)>>"$/;
# bin/mutation-probe.sh only instruments single-line `const NAME = /regex/;` forms.
# Full mutation coverage is planned for T1-E2 (Stryker integration).
#
# L3 gap (mutation probe): the [^>]+ constraint (blocks redirect/> injection) is
# verified by table-driven Section 3 cases (T15, T16a) rather than automated mutation.
# A surviving mutant that replaces [^>]+ with .+ would be caught by T15 (reason-with->).
#
# Run via bin/run-with-timeout.sh (the repo's portable wrapper, not the local function).
MUTATION_PROBE="$AGENTS_DIR/bin/mutation-probe.sh"
RWT17="$AGENTS_DIR/bin/run-with-timeout.sh"
if [[ -f "$MUTATION_PROBE" ]]; then
    probe_out=""
    probe_rc=0
    probe_out=$(bash "$RWT17" 60 bash "$MUTATION_PROBE" "$SENTINEL_PATTERNS" 2>&1) || probe_rc=$?
    if [[ "$probe_rc" -eq 0 ]]; then
        pass "T17.mutation-probe: sentinel-patterns.js passed mutation probe"
    elif echo "$probe_out" | grep -q "no single-line const regex found\|multi-line constant forms"; then
        echo "SKIP: T17.mutation-probe — sentinel-patterns.js uses multi-line const forms; probe has nothing to mutate (T1-E2/Stryker planned for full coverage)"
    else
        fail "T17.mutation-probe: sentinel-patterns.js failed mutation probe (rc=$probe_rc): $(echo "$probe_out" | head -3)"
    fi
else
    echo "SKIP: T17.mutation-probe — bin/mutation-probe.sh not found"
fi

# ---------------------------------------------------------------------------
# Section 4 — Sentinel injection guard cases (C3)
# Verifies that WARNINGS_ACCEPTED_RE_DQ rejects dangerous reason payloads.
# The [^>]+ constraint blocks `>` which blocks redirects, $() substitution, etc.
# The anchored form `^echo "..."$` blocks command chaining.
# EXPECTED: FAIL for NOT_EXPORTED cases until regex constants are added.
#           PASS for NO_MATCH cases (NOT_EXPORTED also fails the match → safe).
# ---------------------------------------------------------------------------

echo ""
echo "=== Section 4: REVIEW_TESTS_WARNINGS_ACCEPTED injection guard cases ==="

# For injection guards we assert NO_MATCH on DQ_RE AND not isStrictSentinel.
# Helper: assert the command is neither a DQ match nor a strict sentinel.
assert_injection_blocked() {
    local desc="$1" cmd="$2"
    local dq_got strict_got
    dq_got=$(eval_sentinel_regex "REVIEW_TESTS_WARNINGS_ACCEPTED_RE_DQ" "$cmd")
    strict_got=$(eval_is_strict "$cmd")
    # NOT_EXPORTED means the regex constant is missing — the injection guard is untestable.
    # Treat as a test failure so the false-green is surfaced explicitly.
    if [[ "$dq_got" == "NOT_EXPORTED" ]]; then
        fail "assert_injection_blocked: REVIEW_TESTS_WARNINGS_ACCEPTED_RE_DQ not exported — cannot test; fix the test (add constant to sentinel-patterns.js) [desc: $desc]"
        return
    fi
    if [[ "$strict_got" == "NOT_EXPORTED" ]]; then
        fail "assert_injection_blocked: isStrictSentinel not exported — cannot test; fix the test [desc: $desc]"
        return
    fi
    if [[ "$dq_got" == "NO_MATCH" ]] && [[ "$strict_got" == "NO" ]]; then
        pass "$desc"
    else
        fail "$desc — DQ_RE=[$dq_got] isStrictSentinel=[$strict_got] for: $cmd"
    fi
}

# Command-substitution injection: $() in reason text.
# [^>]+ already blocks $ before > but $() has no > → could theoretically slip.
# Anchored DQ form prevents: outer form must be exactly echo "<<...: reason>>"
# A $() inside the reason string would still match [^>]+, but the strict anchor
# requires the command to be ONLY the echo — any subshell invocation that changes
# the actual echoed text makes the outer command something different.
# We test the raw forms that attackers would try.
assert_injection_blocked "C3.subshell-dollar-paren" \
    'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: $(evil)>>"'
assert_injection_blocked "C3.subshell-backtick" \
    'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: `evil`>>"'
assert_injection_blocked "C3.semicolon-in-reason" \
    'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: foo; rm -f bar>>"'
assert_injection_blocked "C3.redirect-in-reason" \
    'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: foo > /tmp/x>>"'
assert_injection_blocked "C3.pipe-in-reason" \
    'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: foo | cat>>"'
assert_injection_blocked "C3.and-chain-in-reason" \
    'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: foo && bar>>"'

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
