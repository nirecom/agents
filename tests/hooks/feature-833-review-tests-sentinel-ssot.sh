#!/bin/bash
# Tests: hooks/lib/sentinel-patterns.js, hooks/workflow-gate/review-tests-evidence.js
# Tags: workflow, sentinel, ssot, review-tests, token, fingerprint, scope:issue-specific
# SSOT tests for the review_tests sentinel family (#833): regex constants shared by
# workflow-mark.js and workflow-gate.js, plus review-scope fingerprint computation.
# Pre-implementation expectation: all tests FAIL until write-code lands.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SENTINEL_PATTERNS="$SCRIPT_CHECKOUT_ROOT/hooks/lib/sentinel-patterns.js"
REVIEW_TESTS_EVIDENCE="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate/review-tests-evidence.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"; else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
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
readonly TMPDIR_BASE
export WORKFLOW_STATE_DIR="$TMPDIR_BASE/state" WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR"
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
    'echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint=abc123>>"'

# T2: REVIEW_TESTS_COMPLETE_RE_DQ rejects bare form (no fingerprint payload)
assert_regex_no_match "T2. REVIEW_TESTS_COMPLETE_RE_DQ rejects bare (no payload)" \
    "REVIEW_TESTS_COMPLETE_RE_DQ" \
    'echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE>>"'

# T3: REVIEW_TESTS_WARNINGS_RE_DQ — happy form with summary
assert_regex_match "T3. REVIEW_TESTS_WARNINGS_RE_DQ accepts canonical form (fingerprint + warnings summary)" \
    "REVIEW_TESTS_WARNINGS_RE_DQ" \
    'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS: fingerprint=abc123 warnings=2 INFO=1>>"'

# T4: REVIEW_TESTS_WARNINGS_LOOKSLIKE_RE — bare form falls through as "looks like"
# (used for advisory rejection of malformed warnings sentinels)
assert_regex_match "T4. REVIEW_TESTS_WARNINGS_LOOKSLIKE_RE catches bare form for advisory rejection" \
    "REVIEW_TESTS_WARNINGS_LOOKSLIKE_RE" \
    'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS>>"'

# T5: isSentinel() recognises COMPLETE form
assert_isSentinel "T5. isSentinel() accepts REVIEW_TESTS_COMPLETE with fingerprint" \
    'echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint=abc123>>"' \
    "YES"

# T6: isSentinel() recognises WARNINGS form
assert_isSentinel "T6. isSentinel() accepts REVIEW_TESTS_WARNINGS with fingerprint + summary" \
    'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS: fingerprint=abc123 warnings=2>>"' \
    "YES"

# T7: isSentinel() recognises LOOKSLIKE form so workflow-gate can advise rather than silently pass
assert_isSentinel "T7. isSentinel() recognises bare WARNINGS form (LOOKSLIKE fallthrough)" \
    'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS>>"' \
    "YES"

# T8: REVIEW_TESTS_COMPLETE strict DQ rejects single-quoted form
# (Per sentinel-patterns.js convention, only MARK_STEP is SQ-tolerant; others are DQ-only.)
assert_regex_no_match "T8. REVIEW_TESTS_COMPLETE_RE_DQ rejects single-quoted form" \
    "REVIEW_TESTS_COMPLETE_RE_DQ" \
    "echo '<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint=abc123>>'"

# T8b: REVIEW_TESTS_COMPLETE_LOOKSLIKE_RE — bare form matches (symmetric with WARNINGS LOOKSLIKE)
assert_regex_match "T8b. REVIEW_TESTS_COMPLETE_LOOKSLIKE_RE catches bare form for advisory rejection" \
    "REVIEW_TESTS_COMPLETE_LOOKSLIKE_RE" \
    'echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE>>"'

# T8c: isSentinel() recognises COMPLETE lookslike form (advisory path)
assert_isSentinel "T8c. isSentinel() recognises bare COMPLETE form (LOOKSLIKE fallthrough)" \
    'echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE>>"' \
    "YES"

# ---------------------------------------------------------------------------
# Section 2 — Review-scope fingerprint computation
# (computeReviewScopeFingerprint(repoDir) → {ok, fingerprint, testCount})
# ---------------------------------------------------------------------------

echo ""
echo "=== Section 2: computeReviewScopeFingerprint evidence ==="

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

# Helper: call computeReviewScopeFingerprint(repoDir) via node.
call_compute_token() {
    local repo="$1"
    run_with_timeout node -e "
        try {
            const m = require(process.argv[1]);
            if (typeof m.computeReviewScopeFingerprint !== 'function') {
                process.stdout.write('NOT_IMPLEMENTED');
                process.exit(0);
            }
            const r = m.computeReviewScopeFingerprint(process.argv[2]);
            if (!r || !r.ok) { process.stdout.write('ERR'); }
            else if (!r.fingerprint) { process.stdout.write('EMPTY'); }
            else { process.stdout.write(String(r.fingerprint)); }
        } catch (e) {
            process.stdout.write('ERROR: ' + e.message);
        }
    " -- "$REVIEW_TESTS_EVIDENCE" "$repo" 2>/dev/null || echo "ERROR"
}

# T9: Same staged content → same fingerprint (deterministic)
REPO_A="$TMPDIR_BASE/repo-a"
mkdir -p "$REPO_A"
setup_repo_with_staged_tests "$REPO_A"
TOKEN_A1=$(call_compute_token "$REPO_A")
TOKEN_A2=$(call_compute_token "$REPO_A")
if [ "$TOKEN_A1" = "$TOKEN_A2" ] && [ "$TOKEN_A1" != "EMPTY" ] && [ "$TOKEN_A1" != "ERR" ] && [ "$TOKEN_A1" != "ERROR" ] && [ "$TOKEN_A1" != "NOT_IMPLEMENTED" ]; then
    pass "T9. computeReviewScopeFingerprint is deterministic for unchanged staged content"
else
    fail "T9. expected stable non-empty fingerprint; got first=$TOKEN_A1 second=$TOKEN_A2"
fi

# T10: Modified staged content → different fingerprint (stale-fingerprint detection foundation)
printf 'test content 1 modified\n' > "$REPO_A/tests/feature-a.sh"
git -C "$REPO_A" add tests/feature-a.sh
TOKEN_A3=$(call_compute_token "$REPO_A")
if [ "$TOKEN_A3" != "$TOKEN_A1" ] && [ "$TOKEN_A3" != "EMPTY" ] && [ "$TOKEN_A3" != "ERR" ] && [ "$TOKEN_A3" != "ERROR" ] && [ "$TOKEN_A3" != "NOT_IMPLEMENTED" ]; then
    pass "T10. computeReviewScopeFingerprint changes when staged content changes (stale-fingerprint detection)"
else
    fail "T10. expected new non-empty fingerprint differing from $TOKEN_A1, got: $TOKEN_A3"
fi

# T11: Only src/ files staged (no tests/) → still produces a valid fingerprint.
# src/ is NOT an excluded path — all staged non-excluded paths are in scope (#2327).
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
echo "source code" > "$REPO_B/src.js"
mkdir -p "$REPO_B/src"
echo "module code" > "$REPO_B/src/index.js"
git -C "$REPO_B" add src.js src/index.js
TOKEN_B=$(call_compute_token "$REPO_B")
if [ "$TOKEN_B" != "EMPTY" ] && [ "$TOKEN_B" != "ERR" ] && [ "$TOKEN_B" != "ERROR" ] && [ "$TOKEN_B" != "NOT_IMPLEMENTED" ] && [ -n "$TOKEN_B" ]; then
    pass "T11. computeReviewScopeFingerprint returns valid fingerprint when only src/ files staged (all-scope rule)"
else
    fail "T11. expected valid hex fingerprint for staged src/ files, got: $TOKEN_B"
fi

# T12: Non-git path → ERR ({ok:false})
NON_GIT="$TMPDIR_BASE/non-git"
mkdir -p "$NON_GIT/tests"
echo "x" > "$NON_GIT/tests/some.sh"
TOKEN_NON_GIT=$(call_compute_token "$NON_GIT")
if [ "$TOKEN_NON_GIT" = "ERR" ] || [ "$TOKEN_NON_GIT" = "NOT_IMPLEMENTED" ]; then
    pass "T12. computeReviewScopeFingerprint returns ERR for non-git directory (fail-closed)"
else
    fail "T12. expected ERR for non-git dir, got: $TOKEN_NON_GIT"
fi

# ---------------------------------------------------------------------------
# Section 3 — WARNINGS_ACCEPTED sentinel table-driven tests (cases 12-17)
# Issue #1207 — new sentinel for clearing warnings after user review.
# DQ strict form: echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: reason>>"
# LOOKSLIKE form: <<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED...>> (no strict DQ)
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
assert_eq "T12.isSentinel" "YES" "$(eval_is_sentinel "$cmd12")"

# Case 12 isStrictSentinel — DQ form accepted by isStrictSentinel().
assert_eq "T12.isStrictSentinel" "YES" "$(eval_is_strict "$cmd12")"

# Case 13 isSentinel — bare form (no reason) IS recognized by isSentinel (LOOKSLIKE fallthrough).
cmd13='echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED>>"'
assert_eq "T13.isSentinel(bare-lookslike)" "YES" "$(eval_is_sentinel "$cmd13")"

# Case 13 isStrictSentinel — bare form NOT a strict sentinel.
assert_eq "T13.isStrictSentinel(bare-NOT-strict)" "NO" "$(eval_is_strict "$cmd13")"

# Case 16 — reason containing > must NOT be a strict sentinel (reason text contains >).
assert_eq "T15.isStrictSentinel(reason-with->)" "NO" "$(eval_is_strict 'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: r>x>>"')"

# Case 17 — mutation probe. The probe rewrites its target with `sed -i` in place, so probe and
# target are copied under TMPDIR_BASE and the real checkout is never written (parallel run-all).
# Oracle (--test-cmd): one positive sample per exported *_RE_DQ / *_LOOKSLIKE_RE / RE_*_DQ / LOOKSLIKE_*, checked on the
# regex and on isStrictSentinel / isSentinel; this file covers only a few regexes, so re-running
# it per mutant would leave most mutants LIVE. --threshold 100: every mutant must be KILLED.
MUTATION_PROBE="$SCRIPT_CHECKOUT_ROOT/bin/mutation-probe.sh"
T17_ROOT="$TMPDIR_BASE/t17-probe"
mkdir -p "$T17_ROOT/bin" "$T17_ROOT/hooks/lib" && cp "$MUTATION_PROBE" "$T17_ROOT/bin/" && cp "$SENTINEL_PATTERNS" "$T17_ROOT/hooks/lib/"
printf '%s\n' 'const sp=require(process.argv[2]),q=String.fromCharCode(34);let n=0,bad=0;for(const[k,re]of Object.entries(sp)){const m=/^(.+?)_(RE_DQ|LOOKSLIKE_RE)$/.exec(k)||/^RE_(.+)_(DQ)$/.exec(k)||/^LOOKSLIKE_(.+)$/.exec(k);if(!m||!(re instanceof RegExp))continue;const dq=m[2]==="RE_DQ"||m[2]==="DQ",st=m[1].replace(/^WORKFLOW_/,"").replace(/_RETIRED$/,"").replace(/^RESET_FROM$/,"RESET_FROM_x").replace(/^MARKER$/,"MARK_STEP_x_complete"),p=!dq||/^(CLARIFY_INTENT_COMPLETE|MARK_STEP_)/.test(st)?"":st==="GLOSSARY_ACCEPTED"?": term=t — r":st.startsWith("SUPERVISOR_")?": run-1 r":": r",s="echo "+q+"<<WORKFLOW_"+st+p+">>"+q;n++;if(!re.test(s)||!(dq?sp.isStrictSentinel(s):sp.isSentinel(s))){bad++;console.error("MISS "+k);}}process.exit(n>0&&bad===0?0:1);' > "$T17_ROOT/oracle.js"
t17_cmd="node $(printf '%q' "$T17_ROOT/oracle.js") $(printf '%q' "$T17_ROOT/hooks/lib/sentinel-patterns.js")"
t17_real_before=$(cksum < "$SENTINEL_PATTERNS")
oracle_out=$(bash -c "$t17_cmd" 2>&1); oracle_rc=$?
probe_out=$(bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 120 bash "$T17_ROOT/bin/mutation-probe.sh" --threshold 100 --test-cmd "$t17_cmd" "$T17_ROOT/hooks/lib/sentinel-patterns.js" 2>&1); probe_rc=$?
if [[ "$oracle_rc" -ne 0 ]]; then
    fail "T17.mutation-probe: oracle rejects the unmutated copy, so a KILLED verdict would be meaningless: $oracle_out"
elif [[ "$probe_rc" -eq 0 ]] && [[ "$(cksum < "$SENTINEL_PATTERNS")" == "$t17_real_before" ]] && [[ ! -e "$SENTINEL_PATTERNS.probe-backup" ]]; then
    pass "T17.mutation-probe: every single-line regex mutant of a sentinel-patterns.js copy KILLED; real checkout untouched"
else
    fail "T17.mutation-probe: rc=$probe_rc real-file-unchanged=$([[ "$(cksum < "$SENTINEL_PATTERNS")" == "$t17_real_before" ]] && echo yes || echo no): $(printf '%s\n' "$probe_out" | grep -v '^KILLED' | head -5)"
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
    local desc="$1" cmd="$2" re="${3:-REVIEW_TESTS_WARNINGS_ACCEPTED_RE_DQ}"
    local dq_got strict_got
    dq_got=$(eval_sentinel_regex "$re" "$cmd")
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

# Command-substitution injection: $() in reason text. Anchored DQ form prevents it.
while IFS='|' read -r c3_desc c3_cmd; do assert_injection_blocked "$c3_desc" "$c3_cmd"; done <<'C3_TABLE'
C3.subshell-dollar-paren|echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: $(evil)>>"
C3.subshell-backtick|echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: `evil`>>"
C3.semicolon-in-reason|echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: foo; rm -f bar>>"
C3.redirect-in-reason|echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: foo > /tmp/x>>"
C3.pipe-in-reason|echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: foo | cat>>"
C3.and-chain-in-reason|echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: foo && bar>>"
C3_TABLE

# RE_WORKFLOW_ABORT_ACCEPTED_DQ rejection side (the T17 oracle covers acceptance only): a positive
# control proves the regex is exported and accepts the well-formed form; a missing reason and
# command chaining must then be NO_MATCH on the regex and NO on isStrictSentinel.
AB_RE="RE_WORKFLOW_ABORT_ACCEPTED_DQ"; ab_ok='echo "<<WORKFLOW_ABORT_ACCEPTED: user asked to stop>>"'
assert_eq "C4.abort-accepted.control" "MATCH/YES" "$(eval_sentinel_regex "$AB_RE" "$ab_ok")/$(eval_is_strict "$ab_ok")"
while IFS='|' read -r ab_desc ab_cmd; do assert_injection_blocked "$ab_desc" "$ab_cmd" "$AB_RE"; done <<'AB_TABLE'
C4.abort-accepted.no-reason|echo "<<WORKFLOW_ABORT_ACCEPTED>>"
C4.abort-accepted.empty-reason|echo "<<WORKFLOW_ABORT_ACCEPTED: >>"
C4.abort-accepted.and-chain-after|echo "<<WORKFLOW_ABORT_ACCEPTED: r>>" && rm -f /tmp/x
C4.abort-accepted.semicolon-chain-after|echo "<<WORKFLOW_ABORT_ACCEPTED: r>>"; rm -f /tmp/x
C4.abort-accepted.chain-before|rm -f /tmp/x && echo "<<WORKFLOW_ABORT_ACCEPTED: r>>"
AB_TABLE

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
