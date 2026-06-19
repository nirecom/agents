#!/bin/bash
# tests/feature-920-companion-issues/a-series.sh
# Tests: bin/github-issues/find-companion-issues.sh
# Tags: companion-issues, find-companion-issues, scope:issue-specific
#
# A-series: functional tests for find-companion-issues.sh — 3-pass detection
# (Pass A: xref / Pass B: identifier-namespace / Pass C: sibling-of-parent).
# A1-A3 PASS now (preserve current arg-parse + NON_GITHUB gate). A4-A10 are
# the new RED contract that will pass once the source is rewritten.
#
# L3 gap (what these tests do NOT catch):
# - Whether find-companion-issues.sh performs correctly against a real GitHub API
#   (live network, real JSON pagination, real rate limits).
# - Whether CI-2b in clarify-intent correctly invokes this script at runtime in
#   a live Claude Code session and renders reason in AskUserQuestion.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# A1: no --primary → exit 2
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
    fail "A1: find-companion-issues.sh not found at $FIND_SCRIPT"
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
    fail "A2: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A3: NON_GITHUB gate fires BEFORE any gh issue view
setup_mock
export MOCK_REMOTE_RC=1
export GH_MOCK_BODY_COMMENTS_100='{"body":"","comments":[]}'
if [ -x "$FIND_SCRIPT" ]; then
    ERR=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>&1 >/dev/null)
    RC=$?
    if [ "$RC" -eq 1 ] && [ -n "$ERR" ]; then
        pass "A3: NON_GITHUB remote → exit 1 with stderr diagnostic"
    else
        fail "A3: expected exit 1 with stderr; got rc=$RC err=$ERR"
    fi
else
    fail "A3: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A4: Pass A only — xref (#201) in primary body, no identifier overlap,
# no parent. Expect 1 TSV line with reason=xref.
setup_mock
export GH_MOCK_BODY_COMMENTS_100='{"body":"See also #201","comments":[]}'
export GH_MOCK_VIEW_100='{"number":100,"title":"Unrelated topic","body":"See also #201"}'
export GH_MOCK_ISSUE_100='{"parent":null}'
export GH_MOCK_CAND_201='{"number":201,"title":"Some title","labels":[],"state":"OPEN"}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    LINES=$(printf '%s\n' "$OUT" | grep -cE '^[0-9]+' || true)
    REASON=$(reason_col3 "$OUT")
    if [ "$RC" -eq 0 ] && [ "$LINES" -eq 1 ] && [ "$REASON" = "xref" ]; then
        pass "A4: Pass A only → reason=xref"
    else
        fail "A4: expected 1 line rc=0 reason=xref; got rc=$RC lines=$LINES reason='$REASON' out=$OUT"
    fi
else
    fail "A4: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A5: Pass B only — identifier `supervisor-report` in primary title; matching
# candidate via search; no xref, no parent. Expect reason=ident:supervisor-report.
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"Add supervisor-report hook","body":""}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":null}'
# Mock normalizes the token (- -> _) when building the env-var name —
# hyphens are illegal in bash env names. Test exports underscored form.
export GH_MOCK_SEARCH_supervisor_report='[{"number":201}]'
export GH_MOCK_CAND_201='{"number":201,"title":"Improve supervisor-report output","labels":[],"state":"OPEN"}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    REASON=$(reason_col3 "$OUT")
    if [ "$RC" -eq 0 ] && [ "$REASON" = "ident:supervisor-report" ]; then
        pass "A5: Pass B only → reason=ident:supervisor-report"
    else
        fail "A5: expected reason=ident:supervisor-report; got rc=$RC reason='$REASON' out=$OUT"
    fi
else
    fail "A5: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A6: Pass C gated by B — sibling-of-parent BUT identifier must also overlap.
# #201 has identifier `worktree-end` (match B) AND is sibling under #500 → emitted.
# #202 has no identifier overlap → NOT emitted even though it's a sibling.
# #100 is in the sibling list but self-excluded.
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"Fix worktree-end cleanup","body":""}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":{"number":500}}'
export GH_MOCK_SUBISSUES_500='[{"number":201,"state":"open"},{"number":202,"state":"open"},{"number":100,"state":"open"}]'
export GH_MOCK_SEARCH_worktree_end='[{"number":201}]'
export GH_MOCK_CAND_201='{"number":201,"title":"Improve worktree-end output","labels":[],"state":"OPEN"}'
export GH_MOCK_CAND_202='{"number":202,"title":"Unrelated refactor","labels":[],"state":"OPEN"}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    LINE201=$(printf '%s\n' "$OUT" | grep -E '^201	' || true)
    LINE202=$(printf '%s\n' "$OUT" | grep -E '^202	' || true)
    LINE100=$(printf '%s\n' "$OUT" | grep -E '^100	' || true)
    REASON_201=$(printf '%s' "$LINE201" | awk -F'\t' '{print $3}')
    if [ "$RC" -eq 0 ] && [ -n "$LINE201" ] \
        && echo "$REASON_201" | grep -q "ident:worktree-end" \
        && echo "$REASON_201" | grep -q "sibling-of:#500" \
        && [ -z "$LINE202" ] && [ -z "$LINE100" ]; then
        pass "A6: Pass C gated by B → #201 emitted with B+C reasons; #202/#100 absent"
    else
        fail "A6: rc=$RC line201='$LINE201' line202='$LINE202' line100='$LINE100' out=$OUT"
    fi
else
    fail "A6: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A7: All three passes → reason tags joined in fixed order: xref,ident:<tok>,sibling-of:#<P>
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"Fix worktree-end cleanup","body":""}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"See #201","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":{"number":500}}'
export GH_MOCK_SUBISSUES_500='[{"number":201,"state":"open"}]'
export GH_MOCK_SEARCH_worktree_end='[{"number":201}]'
export GH_MOCK_CAND_201='{"number":201,"title":"Improve worktree-end output","labels":[],"state":"OPEN"}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    REASON=$(reason_col3 "$OUT")
    if [ "$RC" -eq 0 ] && [ "$REASON" = "xref,ident:worktree-end,sibling-of:#500" ]; then
        pass "A7: all three passes → reason='xref,ident:worktree-end,sibling-of:#500'"
    else
        fail "A7: expected joined reason; got rc=$RC reason='$REASON' out=$OUT"
    fi
else
    fail "A7: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A8: --exclude 201,202 with Pass A finding both → neither emitted
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"Foo","body":"Refs #201 and #202"}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"Refs #201 and #202","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":null}'
export GH_MOCK_CAND_201='{"number":201,"title":"X","labels":[],"state":"OPEN"}'
export GH_MOCK_CAND_202='{"number":202,"title":"Y","labels":[],"state":"OPEN"}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 --exclude 201,202 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -qE '^(201|202)	'; then
        pass "A8: --exclude 201,202 drops both"
    else
        fail "A8: expected 201/202 absent; got rc=$RC out=$OUT"
    fi
else
    fail "A8: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A9: meta-labelled candidate dropped
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"Foo","body":"See #201"}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"See #201","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":null}'
export GH_MOCK_CAND_201='{"number":201,"title":"foo","labels":[{"name":"meta"}],"state":"OPEN"}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -qE '^201	'; then
        pass "A9: meta-labelled candidate dropped"
    else
        fail "A9: expected 201 absent (meta); got rc=$RC out=$OUT"
    fi
else
    fail "A9: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A10: two Pass-A-only candidates, equal tag count → ascending sort by issue number.
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"Foo","body":"See #201 and #202"}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"See #201 and #202","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":null}'
export GH_MOCK_CAND_201='{"number":201,"title":"X","labels":[],"state":"OPEN"}'
export GH_MOCK_CAND_202='{"number":202,"title":"Y","labels":[],"state":"OPEN"}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    FIRST_NUM=$(printf '%s\n' "$OUT" | head -1 | awk -F'\t' '{print $1}')
    if [ "$RC" -eq 0 ] && [ "$FIRST_NUM" = "201" ]; then
        pass "A10: equal tag count → ascending sort by issue number (201 first)"
    else
        fail "A10: expected 201 first; got rc=$RC first='$FIRST_NUM' out=$OUT"
    fi
else
    fail "A10: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A11: --max-candidates 0 (invalid, must be ≥1) → exit 2
setup_mock
if [ -x "$FIND_SCRIPT" ]; then
    run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 --max-candidates 0 >/dev/null 2>&1
    RC=$?
    if [ "$RC" -eq 2 ]; then
        pass "A11: --max-candidates 0 → exit 2"
    else
        fail "A11: expected exit 2 for --max-candidates 0; got rc=$RC"
    fi
else
    fail "A11: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A12: primary fetch fails (gh issue view returns non-zero) → exit 1
setup_mock
export GH_MOCK_VIEW_100=fail
if [ -x "$FIND_SCRIPT" ]; then
    ERR=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>&1 >/dev/null)
    RC=$?
    if [ "$RC" -eq 1 ]; then
        pass "A12: gh issue view failure → exit 1"
    else
        fail "A12: expected exit 1 on fetch failure; got rc=$RC err=$ERR"
    fi
else
    fail "A12: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A13: primary with empty body and no identifier tokens in title → exit 0, empty stdout
# (covers the "no signals" edge case; post-rewrite this also covers the old
# "fewer-than-2-useful-tokens" path which no longer exists as a code branch)
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"Fix","body":""}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":null}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
        pass "A13: no signals → exit 0, empty stdout"
    else
        fail "A13: expected exit 0 empty stdout; got rc=$RC out=$OUT"
    fi
else
    fail "A13: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A14: --max-candidates 1 with 2 Pass-A candidates → only 1 emitted
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"Foo","body":"See #201 and #202"}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"See #201 and #202","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":null}'
export GH_MOCK_CAND_201='{"number":201,"title":"X","labels":[],"state":"OPEN"}'
export GH_MOCK_CAND_202='{"number":202,"title":"Y","labels":[],"state":"OPEN"}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 --max-candidates 1 2>/dev/null)
    RC=$?
    LINE_COUNT=$(printf '%s\n' "$OUT" | grep -cE '^[0-9]+' || true)
    if [ "$RC" -eq 0 ] && [ "$LINE_COUNT" -eq 1 ]; then
        pass "A14: --max-candidates 1 caps output to 1 line"
    else
        fail "A14: expected 1 line rc=0; got rc=$RC lines=$LINE_COUNT out=$OUT"
    fi
else
    fail "A14: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A15: --exclude with whitespace + non-numeric entries → still excludes valid numbers, no error
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"Foo","body":"See #201 and #202 and #203"}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"See #201 and #202 and #203","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":null}'
export GH_MOCK_CAND_201='{"number":201,"title":"X","labels":[],"state":"OPEN"}'
export GH_MOCK_CAND_202='{"number":202,"title":"Y","labels":[],"state":"OPEN"}'
export GH_MOCK_CAND_203='{"number":203,"title":"Z","labels":[],"state":"OPEN"}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 --exclude ' 201 , abc , 202 ' 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] \
        && ! printf '%s\n' "$OUT" | grep -qE '^201	' \
        && ! printf '%s\n' "$OUT" | grep -qE '^202	'; then
        pass "A15: --exclude normalizes whitespace+non-numeric; 201/202 excluded"
    else
        fail "A15: expected 201/202 absent; got rc=$RC out=$OUT"
    fi
else
    fail "A15: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A-sec1: shell metacharacters in primary title do not cause command injection (CWE-78)
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"$(echo pwned)","body":""}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":null}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    # stdout must not contain the literal string "pwned" (injection) or the
    # substitution form. We simply verify the script exits cleanly.
    if [ "$RC" -eq 0 ] && ! printf '%s\n' "$OUT" | grep -q "pwned"; then
        pass "A-sec1: shell metacharacters in title do not inject into output"
    else
        fail "A-sec1: possible injection or unexpected exit; rc=$RC out=$OUT"
    fi
else
    fail "A-sec1: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A17: unknown argument → exit 2 (arg-parse exhaustion; preserved across rewrite)
setup_mock
if [ -x "$FIND_SCRIPT" ]; then
    run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 --unknown-flag >/dev/null 2>&1
    RC=$?
    if [ "$RC" -eq 2 ]; then
        pass "A17: unknown argument → exit 2"
    else
        fail "A17: expected exit 2 for unknown argument; got rc=$RC"
    fi
else
    fail "A17: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A-sec2: shell metacharacters in primary BODY do not cause command injection (CWE-78)
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"Normal title","body":"$(echo pwned)"}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"$(echo pwned)","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":null}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && ! printf '%s\n' "$OUT" | grep -q "pwned"; then
        pass "A-sec2: shell metacharacters in body do not inject into output"
    else
        fail "A-sec2: possible body injection or unexpected exit; rc=$RC out=$OUT"
    fi
else
    fail "A-sec2: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A-sec3: injection attempt in --exclude does not execute arbitrary commands (CWE-78)
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"Foo","body":"See #203"}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"See #203","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":null}'
export GH_MOCK_CAND_203='{"number":203,"title":"Z","labels":[],"state":"OPEN"}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 --exclude '201; echo injected' 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && ! printf '%s\n' "$OUT" | grep -q "injected"; then
        pass "A-sec3: --exclude injection attempt does not execute (only numeric entries parsed)"
    else
        fail "A-sec3: possible --exclude injection; rc=$RC out=$OUT"
    fi
else
    fail "A-sec3: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# A16: --max-candidates non-numeric string → exit 2 (same validation as A11)
setup_mock
if [ -x "$FIND_SCRIPT" ]; then
    run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 --max-candidates abc >/dev/null 2>&1
    RC=$?
    if [ "$RC" -eq 2 ]; then
        pass "A16: --max-candidates abc → exit 2"
    else
        fail "A16: expected exit 2 for --max-candidates abc; got rc=$RC"
    fi
else
    fail "A16: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
