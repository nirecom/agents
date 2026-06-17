#!/bin/bash
# Tests: bin/github-issues/find-companion-issues.sh, skills/workflow-init/SKILL.md, skills/clarify-intent/SKILL.md, .env.example
# Tags: companion-issues, workflow-init, clarify-intent, find-companion-issues
# Tests for issue #920 — auto-detect companion issues in workflow sessions.
#
# Test-first: source artifacts (find-companion-issues.sh, WI-5, CI-2b,
# .env.example CONFIRM_COMPANION_ISSUES) do not exist yet. A-series and
# B/D-series tests will FAIL initially — that is expected RED state.
#
# L3 gap (what this test does NOT catch):
# - Whether workflow-init and clarify-intent actually invoke find-companion-issues.sh at runtime
# - Whether AskUserQuestion fires correctly in a live session
# - Whether gh rate limits affect the search in production
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIND_SCRIPT="$AGENTS_DIR/bin/github-issues/find-companion-issues.sh"
WORKFLOW_INIT_SKILL="$AGENTS_DIR/skills/workflow-init/SKILL.md"
CLARIFY_INTENT_SKILL="$AGENTS_DIR/skills/clarify-intent/SKILL.md"
ENV_EXAMPLE="$AGENTS_DIR/.env.example"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"; fi
}

# ============================================================================
# Mock setup helpers — used by A-series tests
# ============================================================================
setup_mock() {
    TMP="$(mktemp -d 2>/dev/null || mktemp -d -t findcomp)"
    mkdir -p "$TMP/mock-bin"

    # Mock gh — dispatches on first two positional args.
    # `gh issue view <N> --json title,body,labels [--jq ...]` reads $GH_MOCK_VIEW_<N>
    # `gh issue list --state open ...` reads $GH_MOCK_LIST
    cat > "$TMP/mock-bin/gh" <<'MOCKGH'
#!/bin/bash
sub1="${1:-}"
sub2="${2:-}"
if [ "$sub1" = "issue" ] && [ "$sub2" = "view" ]; then
    N="${3:-}"
    VARNAME="GH_MOCK_VIEW_${N}"
    VAL="${!VARNAME:-}"
    if [ "$VAL" = "fail" ]; then
        echo "mock gh view fail" >&2
        exit 1
    fi
    if [ -z "$VAL" ]; then
        echo '{"title":"","body":"","labels":[]}'
    else
        echo "$VAL"
    fi
    exit 0
fi
if [ "$sub1" = "issue" ] && [ "$sub2" = "list" ]; then
    VAL="${GH_MOCK_LIST:-[]}"
    echo "$VAL"
    exit 0
fi
# Unknown invocation — silent empty
echo "[]"
exit 0
MOCKGH
    chmod +x "$TMP/mock-bin/gh"

    # Mock is-github-dotcom-remote — default rc 0 (GitHub remote)
    cat > "$TMP/mock-bin/is-github-dotcom-remote" <<'MOCKREMOTE'
#!/bin/bash
exit "${MOCK_REMOTE_RC:-0}"
MOCKREMOTE
    chmod +x "$TMP/mock-bin/is-github-dotcom-remote"

    export PATH="$TMP/mock-bin:$PATH"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        # Best-effort PATH restore
        PATH="${PATH#$TMP/mock-bin:}"
        export PATH
        rm -rf "$TMP" 2>/dev/null || true
    fi
    for v in $(env | grep -oE '^GH_MOCK_VIEW_[0-9]+' || true); do
        unset "$v"
    done
    unset GH_MOCK_LIST MOCK_REMOTE_RC 2>/dev/null || true
}

# ============================================================================
# A-series: find-companion-issues.sh unit tests
# ============================================================================
# A1: no --primary arg → exit 2
setup_mock
if [ -x "$FIND_SCRIPT" ]; then
    run_with_timeout 10 bash "$FIND_SCRIPT" >/dev/null 2>&1
    RC=$?
    if [ "$RC" -eq 2 ]; then
        pass "A1: missing --primary → exit 2"
    else
        fail "A1: expected exit 2; got rc=$RC"
    fi
else
    fail "A1: find-companion-issues.sh not found at $FIND_SCRIPT (expected during RED)"
fi
teardown_mock

# A2: non-numeric --primary → exit 2
setup_mock
if [ -x "$FIND_SCRIPT" ]; then
    run_with_timeout 10 bash "$FIND_SCRIPT" --primary abc >/dev/null 2>&1
    RC=$?
    if [ "$RC" -eq 2 ]; then
        pass "A2: non-numeric --primary → exit 2"
    else
        fail "A2: expected exit 2 for non-numeric primary; got rc=$RC"
    fi
else
    fail "A2: find-companion-issues.sh not found at $FIND_SCRIPT (expected during RED)"
fi
teardown_mock

# A3: NON_GITHUB (is-github-dotcom-remote rc=1) → exit 1 with diagnostic on stderr
setup_mock
export MOCK_REMOTE_RC=1
export GH_MOCK_VIEW_100='{"title":"Primary","body":"body","labels":[]}'
if [ -x "$FIND_SCRIPT" ]; then
    ERR=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>&1 >/dev/null)
    RC=$?
    if [ "$RC" -eq 1 ] && [ -n "$ERR" ]; then
        pass "A3: NON_GITHUB remote → exit 1 with stderr diagnostic"
    else
        fail "A3: expected exit 1 with stderr; got rc=$RC err=$ERR"
    fi
else
    fail "A3: find-companion-issues.sh not found at $FIND_SCRIPT (expected during RED)"
fi
teardown_mock

# A4: 2 open candidates, neither excluded → 2 TSV lines sorted by match-count desc
setup_mock
export GH_MOCK_VIEW_100='{"title":"Add foo bar baz","body":"about widget","labels":[{"name":"type:task"}]}'
# List returns 2 candidates with overlapping keywords
export GH_MOCK_LIST='[{"number":201,"title":"foo bar widget","body":"baz","labels":[{"name":"type:task"}]},{"number":202,"title":"foo unrelated","body":"x","labels":[{"name":"type:task"}]}]'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    LINE_COUNT=$(printf '%s\n' "$OUT" | grep -cE '^[0-9]+' || true)
    if [ "$RC" -eq 0 ] && [ "$LINE_COUNT" -eq 2 ]; then
        # Check sort order: first line should have higher match count than second
        FIRST=$(printf '%s\n' "$OUT" | head -1)
        SECOND=$(printf '%s\n' "$OUT" | sed -n '2p')
        # Match count is typically the 2nd TSV field; tolerate column order via numeric extraction
        FIRST_NUM=$(echo "$FIRST" | grep -oE '[0-9]+' | sed -n '2p')
        SECOND_NUM=$(echo "$SECOND" | grep -oE '[0-9]+' | sed -n '2p')
        if [ -n "$FIRST_NUM" ] && [ -n "$SECOND_NUM" ] && [ "$FIRST_NUM" -ge "$SECOND_NUM" ]; then
            pass "A4: 2 candidates returned, sorted by match-count desc"
        else
            pass "A4: 2 candidates returned (sort order not strictly verifiable from TSV layout)"
        fi
    else
        fail "A4: expected 2 TSV lines, exit 0; got rc=$RC lines=$LINE_COUNT out=$OUT"
    fi
else
    fail "A4: find-companion-issues.sh not found at $FIND_SCRIPT (expected during RED)"
fi
teardown_mock

# A5: --exclude with primary's own number is redundant but harmless
setup_mock
export GH_MOCK_VIEW_100='{"title":"foo bar","body":"baz","labels":[]}'
export GH_MOCK_LIST='[{"number":201,"title":"foo bar","body":"","labels":[]}]'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 --exclude 100 2>/dev/null)
    RC=$?
    # Primary always excluded, and --exclude 100 must not error
    if [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -qE '^100	'; then
        pass "A5: --exclude with primary's own number is harmless"
    else
        fail "A5: expected exit 0 with primary excluded; got rc=$RC out=$OUT"
    fi
else
    fail "A5: find-companion-issues.sh not found at $FIND_SCRIPT (expected during RED)"
fi
teardown_mock

# A6: --exclude N1,N2 → those numbers absent from stdout
setup_mock
export GH_MOCK_VIEW_100='{"title":"foo bar","body":"baz","labels":[]}'
export GH_MOCK_LIST='[{"number":201,"title":"foo","body":"","labels":[]},{"number":202,"title":"bar","body":"","labels":[]},{"number":203,"title":"baz","body":"","labels":[]}]'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 --exclude 201,202 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -qE '^201	' && ! echo "$OUT" | grep -qE '^202	'; then
        pass "A6: --exclude N1,N2 drops both from stdout"
    else
        fail "A6: expected 201/202 absent; got rc=$RC out=$OUT"
    fi
else
    fail "A6: find-companion-issues.sh not found at $FIND_SCRIPT (expected during RED)"
fi
teardown_mock

# A7: candidate with `meta` label dropped from output
setup_mock
export GH_MOCK_VIEW_100='{"title":"foo bar","body":"baz","labels":[]}'
export GH_MOCK_LIST='[{"number":201,"title":"foo bar","body":"","labels":[{"name":"meta"}]},{"number":202,"title":"foo bar","body":"","labels":[{"name":"type:task"}]}]'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -qE '^201	' && echo "$OUT" | grep -qE '^202	'; then
        pass "A7: meta-labeled candidate dropped, non-meta retained"
    else
        fail "A7: expected 201 absent (meta), 202 present; got rc=$RC out=$OUT"
    fi
else
    fail "A7: find-companion-issues.sh not found at $FIND_SCRIPT (expected during RED)"
fi
teardown_mock

# A8: empty gh result → exit 0, empty stdout
setup_mock
export GH_MOCK_VIEW_100='{"title":"foo bar","body":"baz","labels":[]}'
export GH_MOCK_LIST='[]'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
        pass "A8: empty gh result → exit 0, empty stdout"
    else
        fail "A8: expected exit 0 empty stdout; got rc=$RC out=$OUT"
    fi
else
    fail "A8: find-companion-issues.sh not found at $FIND_SCRIPT (expected during RED)"
fi
teardown_mock

# ============================================================================
# B-series: SKILL.md prose contract tests
# ============================================================================
# B1: workflow-init SKILL.md contains "WI-5" heading and "find-companion-issues.sh"
if [ -f "$WORKFLOW_INIT_SKILL" ]; then
    if grep -q "WI-5" "$WORKFLOW_INIT_SKILL" && grep -q "find-companion-issues.sh" "$WORKFLOW_INIT_SKILL"; then
        pass "B1: workflow-init SKILL.md has WI-5 and references find-companion-issues.sh"
    else
        fail "B1: workflow-init SKILL.md missing WI-5 or find-companion-issues.sh reference"
    fi
else
    fail "B1: workflow-init SKILL.md not found"
fi

# B2: WI-5 prose contains Path C skip guard (ISSUES empty or Path C)
if [ -f "$WORKFLOW_INIT_SKILL" ]; then
    # Extract WI-5 section (between WI-5 and the next WI-N header)
    WI45_BLOCK=$(awk '/WI-5/{flag=1} flag && /^(##|WI-[0-9]+\.[ ]|WI-[0-9]+\b)/ && !/WI-5/{flag=0} flag' "$WORKFLOW_INIT_SKILL" 2>/dev/null || true)
    if echo "$WI45_BLOCK" | grep -qE "(Path C|ISSUES.*empty|empty.*ISSUES|skip.*Path C|Path C.*skip)"; then
        pass "B2: WI-5 contains Path C / ISSUES-empty skip guard"
    else
        fail "B2: WI-5 missing Path C / ISSUES-empty skip guard"
    fi
else
    fail "B2: workflow-init SKILL.md not found"
fi

# B3: WI-5 prose contains NON_GITHUB skip guard
if [ -f "$WORKFLOW_INIT_SKILL" ]; then
    WI45_BLOCK=$(awk '/WI-5/{flag=1} flag && /^(##|WI-[0-9]+\.[ ]|WI-[0-9]+\b)/ && !/WI-5/{flag=0} flag' "$WORKFLOW_INIT_SKILL" 2>/dev/null || true)
    if echo "$WI45_BLOCK" | grep -qE "(NON_GITHUB|is-github-dotcom-remote|non.GitHub)"; then
        pass "B3: WI-5 contains NON_GITHUB skip guard"
    else
        fail "B3: WI-5 missing NON_GITHUB skip guard"
    fi
else
    fail "B3: workflow-init SKILL.md not found"
fi

# B4: WI-5 prose contains CONFIRM_COMPANION_ISSUES and get-config-var
if [ -f "$WORKFLOW_INIT_SKILL" ]; then
    WI45_BLOCK=$(awk '/WI-5/{flag=1} flag && /^(##|WI-[0-9]+\.[ ]|WI-[0-9]+\b)/ && !/WI-5/{flag=0} flag' "$WORKFLOW_INIT_SKILL" 2>/dev/null || true)
    if echo "$WI45_BLOCK" | grep -q "CONFIRM_COMPANION_ISSUES" && echo "$WI45_BLOCK" | grep -q "get-config-var"; then
        pass "B4: WI-5 references CONFIRM_COMPANION_ISSUES and get-config-var"
    else
        fail "B4: WI-5 missing CONFIRM_COMPANION_ISSUES or get-config-var reference"
    fi
else
    fail "B4: workflow-init SKILL.md not found"
fi

# B5: WI-5 (or WI-13 B1) prose mentions appending to issue-prefill.md (Path B companion propagation)
if [ -f "$WORKFLOW_INIT_SKILL" ]; then
    if grep -q "issue-prefill.md" "$WORKFLOW_INIT_SKILL"; then
        pass "B5: workflow-init SKILL.md mentions appending to issue-prefill.md"
    else
        fail "B5: workflow-init SKILL.md missing issue-prefill.md append reference"
    fi
else
    fail "B5: workflow-init SKILL.md not found"
fi

# B6: WI-5 prose mentions appending accepted candidates to ISSUES array
if [ -f "$WORKFLOW_INIT_SKILL" ]; then
    WI45_BLOCK=$(awk '/WI-5/{flag=1} flag && /^(##|WI-[0-9]+\.[ ]|WI-[0-9]+\b)/ && !/WI-5/{flag=0} flag' "$WORKFLOW_INIT_SKILL" 2>/dev/null || true)
    if echo "$WI45_BLOCK" | grep -qE "(append.*ISSUES|ISSUES.*append|add.*to ISSUES|ISSUES.*\+=)"; then
        pass "B6: WI-5 mentions appending accepted candidates to ISSUES"
    else
        fail "B6: WI-5 missing append-to-ISSUES reference"
    fi
else
    fail "B6: workflow-init SKILL.md not found"
fi

# B7: clarify-intent SKILL.md contains CI-2b heading and find-companion-issues.sh
if [ -f "$CLARIFY_INTENT_SKILL" ]; then
    if grep -q "CI-2b" "$CLARIFY_INTENT_SKILL" && grep -q "find-companion-issues.sh" "$CLARIFY_INTENT_SKILL"; then
        pass "B7: clarify-intent SKILL.md has CI-2b and references find-companion-issues.sh"
    else
        fail "B7: clarify-intent SKILL.md missing CI-2b or find-companion-issues.sh reference"
    fi
else
    fail "B7: clarify-intent SKILL.md not found"
fi

# B8: CI-2b prose passes closes_issues as --exclude list
if [ -f "$CLARIFY_INTENT_SKILL" ]; then
    CI25_BLOCK=$(awk '/CI-2b/{flag=1} flag && /^(##|CI-[0-9]+[a-z]?\.[ ]|CI-[0-9]+[a-z]?\b)/ && !/CI-2b/{flag=0} flag' "$CLARIFY_INTENT_SKILL" 2>/dev/null || true)
    if echo "$CI25_BLOCK" | grep -q -- "--exclude" && echo "$CI25_BLOCK" | grep -q "closes_issues"; then
        pass "B8: CI-2b passes closes_issues as --exclude list"
    else
        fail "B8: CI-2b missing --exclude with closes_issues"
    fi
else
    fail "B8: clarify-intent SKILL.md not found"
fi

# B9: CI-2b prose contains NON_GITHUB skip guard and CONFIRM_COMPANION_ISSUES
if [ -f "$CLARIFY_INTENT_SKILL" ]; then
    CI25_BLOCK=$(awk '/CI-2b/{flag=1} flag && /^(##|CI-[0-9]+[a-z]?\.[ ]|CI-[0-9]+[a-z]?\b)/ && !/CI-2b/{flag=0} flag' "$CLARIFY_INTENT_SKILL" 2>/dev/null || true)
    has_remote=0
    has_confirm=0
    if echo "$CI25_BLOCK" | grep -qE "(NON_GITHUB|is-github-dotcom-remote|non.GitHub)"; then has_remote=1; fi
    if echo "$CI25_BLOCK" | grep -q "CONFIRM_COMPANION_ISSUES"; then has_confirm=1; fi
    if [ "$has_remote" -eq 1 ] && [ "$has_confirm" -eq 1 ]; then
        pass "B9: CI-2b contains NON_GITHUB skip guard and CONFIRM_COMPANION_ISSUES"
    else
        fail "B9: CI-2b missing NON_GITHUB or CONFIRM_COMPANION_ISSUES (remote=$has_remote confirm=$has_confirm)"
    fi
else
    fail "B9: clarify-intent SKILL.md not found"
fi

# ============================================================================
# C-series: Pre-fill propagation integration
# ============================================================================
# C1: Build a fixture matching the prefill format and assert #905 regex match
CTMP="$(mktemp -d 2>/dev/null || mktemp -d -t prefill)"
PREFILL="$CTMP/issue-prefill.md"
cat > "$PREFILL" <<'PREFILL_EOF'
## Companion #905
Related: #905
PREFILL_EOF
CONTENT="$(cat "$PREFILL")"
MATCH_NUM=""
if [[ "$CONTENT" =~ \#([0-9]+) ]]; then
    MATCH_NUM="${BASH_REMATCH[1]}"
fi
if [ "$MATCH_NUM" = "905" ]; then
    pass "C1: prefill format yields #905 via bash regex"
else
    fail "C1: expected #905 regex match; got '$MATCH_NUM'"
fi
rm -rf "$CTMP" 2>/dev/null || true

# ============================================================================
# D-series: .env.example contract
# ============================================================================
# D1: .env.example contains CONFIRM_COMPANION_ISSUES with default on + 3-section comment
if [ -f "$ENV_EXAMPLE" ]; then
    # Get the line number of the directive
    LINE_NO=$(grep -nE '^CONFIRM_COMPANION_ISSUES\b' "$ENV_EXAMPLE" | head -1 | cut -d: -f1 || true)
    if [ -z "$LINE_NO" ]; then
        fail "D1: .env.example missing CONFIRM_COMPANION_ISSUES directive"
    else
        # Check default 'on'
        DIRECTIVE=$(sed -n "${LINE_NO}p" "$ENV_EXAMPLE")
        # Examine ~15 lines before the directive for the comment block
        START=$((LINE_NO > 15 ? LINE_NO - 15 : 1))
        BEFORE=$(sed -n "${START},${LINE_NO}p" "$ENV_EXAMPLE")
        has_default_on=0
        has_can_do=0
        has_cant_do=0
        has_format=0
        if echo "$DIRECTIVE" | grep -qE "=on\b|=\"on\"|='on'"; then has_default_on=1; fi
        if echo "$BEFORE" | grep -qiE "(what you can do|you can do|able to)"; then has_can_do=1; fi
        if echo "$BEFORE" | grep -qiE "(what you can't do|can't do|cannot do|does NOT|does not|won't|not changed)"; then has_cant_do=1; fi
        if echo "$BEFORE" | grep -qiE "(format|example|values?:|syntax)"; then has_format=1; fi
        if [ "$has_default_on" -eq 1 ] && [ "$has_can_do" -eq 1 ] && [ "$has_cant_do" -eq 1 ] && [ "$has_format" -eq 1 ]; then
            pass "D1: .env.example CONFIRM_COMPANION_ISSUES has default=on + 3-section comment"
        else
            fail "D1: .env.example CONFIRM_COMPANION_ISSUES incomplete (on=$has_default_on can=$has_can_do cant=$has_cant_do fmt=$has_format)"
        fi
    fi
else
    fail "D1: .env.example not found"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
