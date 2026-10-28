#!/bin/bash
# Tests: bin/github-issues/find-pr-by-marker.sh
# Tags: issue-close, workflow, pr, marker, github, scope:issue-specific, gitlab, glab, forge
# Serial: shell-injection guard asserts the fixed path /tmp/F6_INJECT stays absent
# Tests for issue #325 — bin/github-issues/find-pr-by-marker.sh

# Maps issue N → (PR_NUMBER, MERGE_COMMIT) using:
#   primary:  closedByPullRequestsReferences (numbers only) + gh pr view <n>
#             (CLOSED state; unmerged excluded; latest mergedAt wins)
#   fallback: keyword search + exact client-side issue-close-pr-of marker match
# gh-mock applies the script's real --jq to raw API-shaped JSON (#2765).

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIND_SCRIPT="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/find-pr-by-marker.sh"
MOCK_DIR="$SCRIPT_CHECKOUT_ROOT/tests/fixtures/gh-mock"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# --- Existence gate ---------------------------------------------------------
if [ ! -f "$FIND_SCRIPT" ]; then
    echo "FAIL: precondition missing — bin/github-issues/find-pr-by-marker.sh"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

for f in gh doc-append git; do
    if [ -f "$MOCK_DIR/$f" ] && [ ! -x "$MOCK_DIR/$f" ]; then
        chmod +x "$MOCK_DIR/$f" 2>/dev/null || true
    fi
done

setup_tmp_find() {
    TMP="$(mktemp -d)"
    export PATH="$MOCK_DIR:$PATH"
    export GH_MOCK_COMMENT_LOG="$TMP/comments.log"
    : > "$GH_MOCK_COMMENT_LOG"
}

teardown_tmp_find() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset GH_MOCK_COMMENT_LOG
}

# Helper: run find-pr-by-marker.sh and capture PR_NUMBER/MERGE_COMMIT.
run_find() {
    local n="${1:-42}"
    local out rc
    out=$(run_with_timeout 15 bash "$FIND_SCRIPT" "$n" 2>/tmp/find_err.$$)
    rc=$?
    FIND_ERR=$(cat /tmp/find_err.$$ 2>/dev/null)
    rm -f /tmp/find_err.$$
    FIND_OUT="$out"
    unset PR_NUMBER MERGE_COMMIT
    # shellcheck disable=SC1090
    eval "$out" 2>/dev/null
    FIND_PR_NUMBER="${PR_NUMBER:-}"
    FIND_MERGE_COMMIT="${MERGE_COMMIT:-}"
    return $rc
}

# ============================================================================
# F-series — find-pr-by-marker.sh
# ============================================================================

# --- F1: marker fallback when closedByPullRequestsReferences empty
setup_tmp_find
GH_MOCK_MARKER_PR_RESULT="99	abc1234" GH_MOCK_SCENARIO=closed_no_sentinel run_find 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "99" ] && [ "$FIND_MERGE_COMMIT" = "abc1234" ]; then
    pass "F1: marker fallback when closedByPullRequestsReferences empty → PR 99"
else
    fail "F1: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT out=$FIND_OUT"
fi
teardown_tmp_find

# --- F2: closedByPullRequestsReferences primary hit → PR 55 dead1234
setup_tmp_find
GH_MOCK_CLOSED_BY_PR_NUM_FOR_42=55 \
GH_MOCK_PR_MERGE_SHA_FOR_55=dead1234 \
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_find 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "55" ] && [ "$FIND_MERGE_COMMIT" = "dead1234" ]; then
    pass "F2: closedByPullRequestsReferences primary hit → PR 55 dead1234"
else
    fail "F2: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR"
fi
teardown_tmp_find

# --- F3: primary miss + fallback empty + issue CLOSED → exit 1
setup_tmp_find
GH_MOCK_SCENARIO=closed_no_sentinel run_find 42; RC=$?
if [ "$RC" -ne 0 ] && echo "$FIND_ERR" | grep -qi "no PR"; then
    pass "F3: primary miss + fallback empty → exit 1"
else
    fail "F3: rc=$RC err=$FIND_ERR"
fi
teardown_tmp_find

# --- F4: two marker PRs with different mergedAt → the newer (PR 11) is selected.
# The newer PR is listed first so list order alone cannot satisfy the case.
setup_tmp_find
RAW_F4='[{"number":11,"mergedAt":"2026-02-01T00:00:00Z","mergeCommit":{"oid":"new11bbb"},"body":"y\n<!-- issue-close-pr-of: 42 -->"},{"number":10,"mergedAt":"2026-01-01T00:00:00Z","mergeCommit":{"oid":"old10aaa"},"body":"x\n<!-- issue-close-pr-of: 42 -->"}]'
GH_MOCK_MARKER_PR_RAW="$RAW_F4" GH_MOCK_SCENARIO=closed_no_sentinel run_find 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "11" ] && [ "$FIND_MERGE_COMMIT" = "new11bbb" ]; then
    pass "F4: two marker PRs → latest mergedAt selected (PR 11)"
else
    fail "F4: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT"
fi
teardown_tmp_find

# --- F5: OPEN issue + no primary marker → exit 1
setup_tmp_find
GH_MOCK_SCENARIO=issue_task run_find 42; RC=$?
if [ "$RC" -ne 0 ]; then
    pass "F5: OPEN issue + no primary → exit 1"
else
    fail "F5: expected exit 1 for OPEN issue with no PR (rc=$RC)"
fi
teardown_tmp_find

# --- F6: non-numeric N → exit 1, no shell injection
setup_tmp_find
GH_MOCK_SCENARIO=closed_no_sentinel run_with_timeout 15 bash "$FIND_SCRIPT" "42; touch /tmp/F6_INJECT" >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f /tmp/F6_INJECT ]; then
    pass "F6: non-numeric N → exit 1"
else
    fail "F6: rc=$RC inject=$([ -f /tmp/F6_INJECT ] && echo yes || echo no)"
    rm -f /tmp/F6_INJECT 2>/dev/null
fi
teardown_tmp_find

# --- F7: closedByPullRequestsReferences primary wins over stale marker
# Scenario: marker PR 399 has stale sha. Issue was actually closed by PR 414
# (via closedByPullRequestsReferences). Primary should win.
setup_tmp_find
GH_MOCK_MARKER_PR_RESULT="399	stale111" \
GH_MOCK_CLOSED_BY_PR_NUM_FOR_42=414 \
GH_MOCK_PR_MERGE_SHA_FOR_414=real4567 \
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_find 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "414" ] && [ "$FIND_MERGE_COMMIT" = "real4567" ]; then
    pass "F7: closedByPullRequestsReferences primary wins over stale marker"
else
    fail "F7: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR"
fi
teardown_tmp_find

# --- F8: multiple closedByPullRequestsReferences → the most recent merge wins.
# The newer PR is listed first so list order alone cannot satisfy the case.
setup_tmp_find
GH_MOCK_CLOSED_BY_PR_NUM_FOR_42="200 100" \
GH_MOCK_PR_MERGE_SHA_FOR_100=oldsha100 \
GH_MOCK_PR_MERGED_AT_FOR_100=2026-01-01T00:00:00Z \
GH_MOCK_PR_MERGE_SHA_FOR_200=newsha200 \
GH_MOCK_PR_MERGED_AT_FOR_200=2026-02-01T00:00:00Z \
GH_MOCK_SCENARIO=closed_multi_reference \
    run_find 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "200" ] && [ "$FIND_MERGE_COMMIT" = "newsha200" ]; then
    pass "F8: closed_multi_reference → sort_by(mergedAt)|last selects PR 200"
else
    fail "F8: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR"
fi
teardown_tmp_find

# ============================================================================
# Cross-repo tests — --repo routing (#1100/#1101) + fallback-skip (#1204)
# F9/F10 exercise the PRIMARY path (closedByPullRequestsReferences) with a
# --repo slug (short + full form). F11 asserts that when --repo is set and the
# primary returns empty, the marker fallback is SKIPPED (never searches the
# current repo — #1204: a cross-repo PR is definitively in the named repo).
# ============================================================================

# Helper for cross-repo: run find-pr-by-marker.sh with a --repo flag.
run_find_repo() {
    local repo="$1" n="${2:-42}"
    local out rc
    out=$(run_with_timeout 15 bash "$FIND_SCRIPT" --repo "$repo" "$n" 2>/tmp/find_repo_err.$$)
    rc=$?
    FIND_ERR=$(cat /tmp/find_repo_err.$$ 2>/dev/null)
    rm -f /tmp/find_repo_err.$$
    FIND_OUT="$out"
    unset PR_NUMBER MERGE_COMMIT
    eval "$out" 2>/dev/null
    FIND_PR_NUMBER="${PR_NUMBER:-}"
    FIND_MERGE_COMMIT="${MERGE_COMMIT:-}"
    return $rc
}

# --- F9: --repo <short-name> (short form) routes the PRIMARY lookup to the
# named repo. closedByPullRequestsReferences resolves PR 77/bbb9999; no fallback.
setup_tmp_find
GH_MOCK_CLOSED_BY_PR_NUM_FOR_42=77 \
GH_MOCK_PR_MERGE_SHA_FOR_77=bbb9999 \
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_find_repo "my-private-repo" 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "77" ] && [ "$FIND_MERGE_COMMIT" = "bbb9999" ]; then
    pass "F9: --repo my-private-repo (short form) primary → PR 77 bbb9999"
else
    fail "F9: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR (expected --repo short-form primary)"
fi
teardown_tmp_find

# --- F10: --repo <owner/repo> (full form) routes the PRIMARY lookup to the
# named repo. closedByPullRequestsReferences resolves PR 88/ccc1111; no fallback.
setup_tmp_find
GH_MOCK_CLOSED_BY_PR_NUM_FOR_42=88 \
GH_MOCK_PR_MERGE_SHA_FOR_88=ccc1111 \
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_find_repo "nirecom/my-private-repo" 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "88" ] && [ "$FIND_MERGE_COMMIT" = "ccc1111" ]; then
    pass "F10: --repo nirecom/my-private-repo (full form) primary → PR 88 ccc1111"
else
    fail "F10: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR (expected --repo full-form primary)"
fi
teardown_tmp_find

# --- F11 (#1204): --repo set + primary empty → fallback SKIPPED → exit 1.
# GH_MOCK_MARKER_PR_RESULT is deliberately set (66/dddeadbe). If the fallback
# `gh pr list` fired against the current repo it would find this marker PR and
# return rc=0. The #1204 fix skips the fallback whenever --repo is set, so the
# script must exit non-zero with no PR found — proving the fallback did NOT run.
setup_tmp_find
GH_MOCK_MARKER_PR_RESULT="66	dddeadbe" GH_MOCK_SCENARIO=closed_no_sentinel \
    run_find_repo "my-private-repo" 42; RC=$?
if [ "$RC" -ne 0 ] && [ -z "$FIND_PR_NUMBER" ]; then
    pass "F11: --repo set + primary empty → fallback skipped (exit 1, no PR)"
else
    fail "F11: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT (fallback should be skipped when --repo set)"
fi
teardown_tmp_find

# ============================================================================
# #2765 regressions — the real API returns PR numbers only (no mergedAt /
# mergeCommit), so the merge data must be resolved per PR via `gh pr view`.
# ============================================================================

# --- F12: CLOSED issue, one merged PR number only → PR and SHA both non-empty.
# The old implementation read mergeCommit from the references and got an empty
# SHA, so the primary path never succeeded.
setup_tmp_find
GH_MOCK_CLOSED_BY_PR_NUM_FOR_42=55 \
GH_MOCK_PR_MERGE_SHA_FOR_55=dead1234 \
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_find 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "55" ] && [ "$FIND_MERGE_COMMIT" = "dead1234" ]; then
    pass "F12: numbers-only references resolved via pr view → PR 55 dead1234"
else
    fail "F12: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR"
fi
teardown_tmp_find

# --- F13: unmerged PR 300 (no merge SHA) is excluded; merged PR 301 is chosen.
setup_tmp_find
GH_MOCK_CLOSED_BY_PR_NUM_FOR_42="300 301" \
GH_MOCK_PR_MERGE_SHA_FOR_301=feed3010 \
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_find 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "301" ] && [ "$FIND_MERGE_COMMIT" = "feed3010" ]; then
    pass "F13: unmerged PR 300 excluded → merged PR 301"
else
    fail "F13: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR"
fi
teardown_tmp_find

# --- F14: fallback must match the marker exactly — a PR for issue 420 does not
# satisfy a search for issue 42 (keyword search is loose on the number token).
setup_tmp_find
RAW_F14='[{"number":900,"mergedAt":"2026-03-01T00:00:00Z","mergeCommit":{"oid":"bad9000"},"body":"z\n<!-- issue-close-pr-of: 420 -->"}]'
GH_MOCK_MARKER_PR_RAW="$RAW_F14" GH_MOCK_SCENARIO=closed_no_sentinel run_find 42; RC=$?
if [ "$RC" -eq 1 ] && [ -z "$FIND_PR_NUMBER" ] && echo "$FIND_ERR" | grep -q "no PR found for #42"; then
    pass "F14: fallback rejects marker of issue 420 for N=42 → exit 1"
else
    fail "F14: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR"
fi
teardown_tmp_find

# --- F15: candidates for 420 and 42 mixed → the 42 PR is chosen even though the
# 420 PR merged later.
setup_tmp_find
RAW_F15='[{"number":900,"mergedAt":"2026-03-01T00:00:00Z","mergeCommit":{"oid":"bad9000"},"body":"<!-- issue-close-pr-of: 420 -->"},{"number":42,"mergedAt":"2026-01-15T00:00:00Z","mergeCommit":{"oid":"good420"},"body":"<!-- issue-close-pr-of: 42 -->"}]'
GH_MOCK_MARKER_PR_RAW="$RAW_F15" GH_MOCK_SCENARIO=closed_no_sentinel run_find 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "42" ] && [ "$FIND_MERGE_COMMIT" = "good420" ]; then
    pass "F15: marker 420 ignored, marker 42 PR selected"
else
    fail "F15: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR"
fi
teardown_tmp_find

# --- F16: --repo is forwarded to the per-PR `gh pr view` lookup, not only to
# `gh issue view`.
setup_tmp_find
GH_MOCK_CALL_LOG="$TMP/calls.log"
: > "$GH_MOCK_CALL_LOG"
export GH_MOCK_CALL_LOG
GH_MOCK_CLOSED_BY_PR_NUM_FOR_42=77 \
GH_MOCK_PR_MERGE_SHA_FOR_77=bbb9999 \
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_find_repo "nirecom/my-private-repo" 42; RC=$?
if [ "$RC" -eq 0 ] \
    && grep -E '^issue view .*--repo nirecom/my-private-repo' "$GH_MOCK_CALL_LOG" >/dev/null 2>&1 \
    && grep -E '^pr view 77 .*--repo nirecom/my-private-repo' "$GH_MOCK_CALL_LOG" >/dev/null 2>&1; then
    pass "F16: --repo forwarded to gh pr view 77"
else
    fail "F16: rc=$RC calls=[$(cat "$GH_MOCK_CALL_LOG" 2>/dev/null)]"
fi
unset GH_MOCK_CALL_LOG
teardown_tmp_find

# --- F17: references exist but every PR is unmerged → no PR (exit 1).
setup_tmp_find
GH_MOCK_CLOSED_BY_PR_NUM_FOR_42="300 302" GH_MOCK_SCENARIO=closed_no_sentinel run_find 42; RC=$?
if [ "$RC" -eq 1 ] && [ -z "$FIND_PR_NUMBER" ] && echo "$FIND_ERR" | grep -q "no PR found for #42"; then
    pass "F17: all referenced PRs unmerged → exit 1"
else
    fail "F17: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR"
fi
teardown_tmp_find

# --- F18: fallback candidate without a merge commit is not accepted → exit 1.
setup_tmp_find
RAW_F18='[{"number":21,"mergedAt":null,"mergeCommit":null,"body":"<!-- issue-close-pr-of: 42 -->"}]'
GH_MOCK_MARKER_PR_RAW="$RAW_F18" GH_MOCK_SCENARIO=closed_no_sentinel run_find 42; RC=$?
if [ "$RC" -eq 1 ] && [ -z "$FIND_PR_NUMBER" ]; then
    pass "F18: fallback candidate without merge commit → exit 1"
else
    fail "F18: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR"
fi
teardown_tmp_find

# --- F19: a reference from another repository is resolved in THAT repository,
# not in the issue's repository (same PR number could exist in both).
setup_tmp_find
GH_MOCK_CALL_LOG="$TMP/calls.log"
: > "$GH_MOCK_CALL_LOG"
export GH_MOCK_CALL_LOG
GH_MOCK_CLOSED_BY_PR_NUM_FOR_42=88 \
GH_MOCK_CLOSED_BY_PR_REPO_FOR_88=other-owner/other-repo \
GH_MOCK_PR_MERGE_SHA_FOR_88=ccc8888 \
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_find 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "88" ] \
    && grep -E '^pr view 88 .*--repo other-owner/other-repo' "$GH_MOCK_CALL_LOG" >/dev/null 2>&1; then
    pass "F19: cross-repo reference resolved with --repo other-owner/other-repo"
else
    fail "F19: rc=$RC pr=$FIND_PR_NUMBER calls=[$(cat "$GH_MOCK_CALL_LOG" 2>/dev/null)]"
fi
unset GH_MOCK_CALL_LOG
teardown_tmp_find

# --- F20: a failed per-PR lookup aborts (exit 1) instead of letting the older
# merged PR win silently.
setup_tmp_find
GH_MOCK_CLOSED_BY_PR_NUM_FOR_42="200 100" \
GH_MOCK_PR_VIEW_FAIL_FOR_200=1 \
GH_MOCK_PR_MERGE_SHA_FOR_100=old1000 \
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_find 42; RC=$?
if [ "$RC" -eq 1 ] && [ -z "$FIND_PR_NUMBER" ] && echo "$FIND_ERR" | grep -q "gh pr view 200 failed"; then
    pass "F20: failed per-PR lookup → exit 1, older PR not selected"
else
    fail "F20: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR"
fi
teardown_tmp_find

# --- F21 / F22: reversed list order of F4 / F8 — the older merge is listed
# first, so a pick-first implementation fails while latest-mergedAt passes.
setup_tmp_find
RAW_F21='[{"number":10,"mergedAt":"2026-01-01T00:00:00Z","mergeCommit":{"oid":"old10aaa"},"body":"x\n<!-- issue-close-pr-of: 42 -->"},{"number":11,"mergedAt":"2026-02-01T00:00:00Z","mergeCommit":{"oid":"new11bbb"},"body":"y\n<!-- issue-close-pr-of: 42 -->"}]'
GH_MOCK_MARKER_PR_RAW="$RAW_F21" GH_MOCK_SCENARIO=closed_no_sentinel run_find 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "11" ] && [ "$FIND_MERGE_COMMIT" = "new11bbb" ]; then
    pass "F21: marker PRs, older listed first → latest mergedAt still selected (PR 11)"
else
    fail "F21: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT"
fi
teardown_tmp_find

setup_tmp_find
GH_MOCK_CLOSED_BY_PR_NUM_FOR_42="100 200" \
GH_MOCK_PR_MERGE_SHA_FOR_100=oldsha100 \
GH_MOCK_PR_MERGED_AT_FOR_100=2026-01-01T00:00:00Z \
GH_MOCK_PR_MERGE_SHA_FOR_200=newsha200 \
GH_MOCK_PR_MERGED_AT_FOR_200=2026-02-01T00:00:00Z \
GH_MOCK_SCENARIO=closed_multi_reference \
    run_find 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "200" ] && [ "$FIND_MERGE_COMMIT" = "newsha200" ]; then
    pass "F22: references, older listed first → latest mergedAt still selected (PR 200)"
else
    fail "F22: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR"
fi
teardown_tmp_find

# --- F23: first reference resolves, a LATER reference's lookup fails → exit 1
# with no PR_NUMBER=/MERGE_COMMIT= output (the earlier PR must not win).
setup_tmp_find
GH_MOCK_CLOSED_BY_PR_NUM_FOR_42="100 200" \
GH_MOCK_PR_MERGE_SHA_FOR_100=old1000 \
GH_MOCK_PR_MERGED_AT_FOR_100=2026-01-01T00:00:00Z \
GH_MOCK_PR_VIEW_FAIL_FOR_200=1 \
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_find 42; RC=$?
if [ "$RC" -eq 1 ] && ! echo "$FIND_OUT" | grep -qE '^(PR_NUMBER|MERGE_COMMIT)=' \
    && echo "$FIND_ERR" | grep -q "gh pr view 200 failed"; then
    pass "F23: later per-PR lookup fails → exit 1, no PR/commit output"
else
    fail "F23: rc=$RC out=$FIND_OUT err=$FIND_ERR"
fi
teardown_tmp_find

# G-series (#2308): GitLab forge cases.
# shellcheck source=feature-325-find-pr-by-marker/gitlab-cases.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-325-find-pr-by-marker/gitlab-cases.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
