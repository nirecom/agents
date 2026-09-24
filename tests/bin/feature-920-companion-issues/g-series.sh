#!/bin/bash
# tests/feature-920-companion-issues/g-series.sh
# Tests: bin/github-issues/find-companion-issues.sh, bin/github-issues/lib/companion-passes.sh
# Tags: companion-issues, find-companion-issues, file-overlap-tag, kw-tag, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Whether real GitHub API body parsing captures all code file references correctly.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Helper: get reason column for a specific issue number from TSV output
reason_for_num() {
    local output="$1" num="$2"
    printf '%s\n' "$output" | grep -E "^${num}	" | awk -F'\t' '{print $3}'
}

# G1: file:<basename> tag emitted when primary and candidate bodies share a
# code-file path. Primary body and candidate #201 body both mention
# hooks/enforce-worktree.js (same path form, so the intersection holds under
# either full-path or basename matching semantics). #201 enters the candidate
# set via Pass A xref.
# Expected: reason for #201 contains file:enforce-worktree.js
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"Fix guard behavior","body":"See #201 and hooks/enforce-worktree.js for details"}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"See #201 and hooks/enforce-worktree.js for details","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":null}'
export GH_MOCK_BODY_COMMENTS_201='{"body":"This touches hooks/enforce-worktree.js implementation","comments":[]}'
export GH_MOCK_CAND_201='{"number":201,"title":"Improve guard output","labels":[],"state":"OPEN"}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    REASON=$(reason_for_num "$OUT" "201")
    if [ "$RC" -eq 0 ] && echo "$REASON" | grep -q "file:enforce-worktree.js"; then
        pass "G1: file:enforce-worktree.js tag in reason for #201"
    else
        fail "G1: expected file:enforce-worktree.js in reason (pre-implementation — tag not yet added); got reason='$REASON' rc=$RC"
    fi
else
    fail "G1: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# G2: No file: tag when bodies don't share any file path.
# Primary body mentions hooks/enforce-worktree.js; candidate body mentions bin/doc-append.py.
# Expected: reason for #201 does NOT contain file:
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"Fix enforce-worktree hook","body":"See #201 and hooks/enforce-worktree.js"}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"See #201 and hooks/enforce-worktree.js","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":null}'
export GH_MOCK_BODY_COMMENTS_201='{"body":"This touches bin/doc-append.py only","comments":[]}'
export GH_MOCK_CAND_201='{"number":201,"title":"Update doc-append script","labels":[],"state":"OPEN"}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    REASON=$(reason_for_num "$OUT" "201")
    if [ "$RC" -eq 0 ] && ! echo "$REASON" | grep -q "file:"; then
        pass "G2: no file: tag when bodies share no common file path"
    else
        fail "G2: expected no file: tag (pre-implementation check); got reason='$REASON' rc=$RC"
    fi
else
    fail "G2: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# G3: kw:<n> tag emitted when n>=2 title-keyword overlap.
# Primary title: "Fix database migration rollback strategy"
# Candidate #201 title: "Improve database migration rollback approach"
# Shared non-identifier keywords: database, migration, rollback (n=3, all >=4 chars)
# Expected: reason for #201 contains kw:3
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"Fix database migration rollback strategy","body":"See #201"}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"See #201","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":null}'
export GH_MOCK_CAND_201='{"number":201,"title":"Improve database migration rollback approach","labels":[],"state":"OPEN"}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    REASON=$(reason_for_num "$OUT" "201")
    if [ "$RC" -eq 0 ] && echo "$REASON" | grep -qE "kw:[2-9]"; then
        pass "G3: kw:<n> tag with n>=2 for 3-keyword overlap"
    else
        fail "G3: expected kw:N (N>=2) in reason (pre-implementation — kw: tag not yet added); got reason='$REASON' rc=$RC"
    fi
else
    fail "G3: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# G4: No kw: tag when only 1 overlapping title keyword (n=1).
# Primary: "Fix database timeout" — candidate: "Update database connection pool"
# Only "database" overlaps (1 token, n<2 → no tag)
# Expected: reason for #201 does NOT contain kw:
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"Fix database timeout","body":"See #201"}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"See #201","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":null}'
export GH_MOCK_CAND_201='{"number":201,"title":"Update database connection pool","labels":[],"state":"OPEN"}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    REASON=$(reason_for_num "$OUT" "201")
    if [ "$RC" -eq 0 ] && ! echo "$REASON" | grep -q "kw:"; then
        pass "G4: no kw: tag when only 1 overlapping keyword"
    else
        fail "G4: expected no kw: tag with 1 overlap (pre-implementation check); got reason='$REASON' rc=$RC"
    fi
else
    fail "G4: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# G5: kw:<n> and file:<basename> both count toward tag_count (sort order).
# #202 has BOTH new tags (file overlap + 3-keyword title overlap); #201 is
# xref-only. Both are xref'd in the primary body. The multi-tag candidate is
# deliberately the HIGHER issue number: ascending-number tie-break alone would
# put #201 first, so #202 appearing first proves tag_count includes the new
# tags and drives the sort.
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"Fix database migration rollback handler","body":"See #201 and #202 — hooks/enforce-worktree.js"}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"See #201 and #202 — hooks/enforce-worktree.js","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":null}'
export GH_MOCK_BODY_COMMENTS_201='{"body":"Unrelated change","comments":[]}'
export GH_MOCK_CAND_201='{"number":201,"title":"Unrelated cleanup","labels":[],"state":"OPEN"}'
export GH_MOCK_BODY_COMMENTS_202='{"body":"Touches hooks/enforce-worktree.js database migration rollback","comments":[]}'
export GH_MOCK_CAND_202='{"number":202,"title":"Improve database migration rollback approach","labels":[],"state":"OPEN"}'
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    REASON_202=$(reason_for_num "$OUT" "202")
    FIRST_NUM=$(printf '%s\n' "$OUT" | head -1 | awk -F'\t' '{print $1}')
    if [ "$RC" -eq 0 ] \
        && echo "$REASON_202" | grep -q "file:" \
        && echo "$REASON_202" | grep -qE "kw:[2-9]" \
        && [ "$FIRST_NUM" = "202" ]; then
        pass "G5: #202 with kw:+file: tags sorts before xref-only #201 (tag_count includes new tags)"
    else
        fail "G5: expected #202 first with kw:+file: tags (pre-implementation — new tags not yet added); got first='$FIRST_NUM' reason_202='$REASON_202' rc=$RC"
    fi
else
    fail "G5: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
