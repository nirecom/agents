#!/bin/bash
# Tests: bin/github-issues/find-pr-by-marker.sh
# Tags: issue-close, workflow, pr, marker, github, scope:issue-specific, gitlab, glab, forge
# Serial: shell-injection guard asserts the fixed path /tmp/F6_INJECT stays absent
# Tests for issue #325 — bin/github-issues/find-pr-by-marker.sh

# Maps issue N → (PR_NUMBER, MERGE_COMMIT) using:
#   primary:  gh issue view --json closedByPullRequestsReferences
#             (CLOSED state, sort_by mergedAt, last entry's PR + mergeCommit.oid)
#   fallback: marker-based PR search (issue-close-pr-of:N in PR body)
#
# RED: this suite fails clean while the script is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIND_SCRIPT="$AGENTS_DIR/bin/github-issues/find-pr-by-marker.sh"
MOCK_DIR="$AGENTS_DIR/tests/fixtures/gh-mock"

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
    export AGENTS_CONFIG_DIR="$TMP"
    export PATH="$MOCK_DIR:$PATH"
    export GH_MOCK_COMMENT_LOG="$TMP/comments.log"
    : > "$GH_MOCK_COMMENT_LOG"
}

teardown_tmp_find() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset AGENTS_CONFIG_DIR GH_MOCK_COMMENT_LOG
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

# --- F4: multiple PRs with marker → latest by mergedAt selected (PR 100)
# The mock returns the pre-jq'd output (latest entry after sort_by(.mergedAt) | last).
setup_tmp_find
GH_MOCK_MARKER_PR_RESULT="100	cafe4567" GH_MOCK_SCENARIO=closed_no_sentinel run_find 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "100" ] && [ "$FIND_MERGE_COMMIT" = "cafe4567" ]; then
    pass "F4: multiple PRs with marker → latest mergedAt selected (PR 100)"
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

# --- F8: multiple closedByPullRequestsReferences → sort_by(mergedAt)|last picks most recent
setup_tmp_find
GH_MOCK_SCENARIO=closed_multi_reference \
    run_find 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "200" ]; then
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
# G-series (#2308) — GitLab forge path. CPR-ORTH mirror of the GitHub F-series:
# primary `glab api .../closed_by`, marker fallback across merged MR
# descriptions, primary-wins, and the gitlab-only edges (unresolvable project,
# cross-repo rejection). Forge is forced with a fake bin/detect-forge-type CLI
# under AGENTS_CONFIG_DIR; glab is a bash mock keyed by GL_MOCK_* env.
# ============================================================================

# setup_tmp_gl: fake detect-forge-type (gitlab) + glab mock; SHIM_PROJECT picks
# the resolved project path (empty = unresolvable). GL_MOCK_CLOSED_BY /
# GL_MOCK_MARKER hold pre-jq'd `<iid>\t<sha>` lines (real tab), empty = miss.
setup_tmp_gl() {
    TMP="$(mktemp -d)"
    export AGENTS_CONFIG_DIR="$TMP"
    mkdir -p "$TMP/bin" "$TMP/glmockbin"
    cat > "$TMP/bin/detect-forge-type" <<'NODE'
"use strict";
const argv = process.argv;
function arg(n){const i=argv.indexOf(n);return i>=0&&i+1<argv.length?argv[i+1]:null;}
const field = arg("--field");
if (field === "type") process.stdout.write("gitlab\n");
else if (field === "project") process.stdout.write((process.env.SHIM_PROJECT === undefined ? "acme/widgets" : process.env.SHIM_PROJECT) + "\n");
else process.stdout.write("\n");
NODE
    export GL_LOG="$TMP/glab.log"
    : > "$GL_LOG"
    cat > "$TMP/glmockbin/glab" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GL_LOG"
# GL_MOCK_EXIT simulates a glab API failure (auth/network): the call is logged
# (so callers can prove glab WAS queried) then exits non-zero before any output.
[ -n "${GL_MOCK_EXIT:-}" ] && exit "$GL_MOCK_EXIT"
case "$*" in
    *closed_by*) [ -n "${GL_MOCK_CLOSED_BY:-}" ] && printf '%s\n' "$GL_MOCK_CLOSED_BY"; exit 0 ;;
    *merge_requests*) [ -n "${GL_MOCK_MARKER:-}" ] && printf '%s\n' "$GL_MOCK_MARKER"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$TMP/glmockbin/glab"
    _GL_OLDPATH="$PATH"
    export PATH="$TMP/glmockbin:$PATH"
}

teardown_tmp_gl() {
    export PATH="$_GL_OLDPATH"
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then rm -rf "$TMP"; fi
    unset AGENTS_CONFIG_DIR GL_LOG SHIM_PROJECT GL_MOCK_CLOSED_BY GL_MOCK_MARKER GL_MOCK_EXIT TMP
}

# run_find_gl [--repo <slug>] <N>: run under the gitlab setup; parses PR_NUMBER /
# MERGE_COMMIT like run_find and exposes FIND_ERR.
run_find_gl() {
    local out rc
    out=$(run_with_timeout 15 bash "$FIND_SCRIPT" "$@" 2>/tmp/find_gl_err.$$)
    rc=$?
    FIND_ERR=$(cat /tmp/find_gl_err.$$ 2>/dev/null)
    rm -f /tmp/find_gl_err.$$
    FIND_OUT="$out"
    unset PR_NUMBER MERGE_COMMIT
    eval "$out" 2>/dev/null
    FIND_PR_NUMBER="${PR_NUMBER:-}"
    FIND_MERGE_COMMIT="${MERGE_COMMIT:-}"
    return $rc
}

GL_CB=$(printf '3\tsha1230')   # closed_by primary line
GL_MK=$(printf '5\tsha4560')   # marker fallback line

# --- G1 (mirror F2): gitlab primary closed_by hit → PR 3 / sha1230.
setup_tmp_gl
GL_MOCK_CLOSED_BY="$GL_CB" run_find_gl 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "3" ] && [ "$FIND_MERGE_COMMIT" = "sha1230" ]; then
    pass "G1: gitlab primary closed_by hit → PR 3 sha1230"
else
    fail "G1: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR"
fi
teardown_tmp_gl

# --- G2 (mirror F1): primary empty → marker fallback across merged MRs → PR 5.
setup_tmp_gl
GL_MOCK_MARKER="$GL_MK" run_find_gl 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "5" ] && [ "$FIND_MERGE_COMMIT" = "sha4560" ]; then
    pass "G2: gitlab marker fallback when closed_by empty → PR 5 sha4560"
else
    fail "G2: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR"
fi
teardown_tmp_gl

# --- G3 (mirror F3): primary miss + fallback empty → exit 1 "no MR".
setup_tmp_gl
run_find_gl 42; RC=$?
if [ "$RC" -ne 0 ] && echo "$FIND_ERR" | grep -qi "no MR"; then
    pass "G3: gitlab primary miss + fallback empty → exit 1 (no MR)"
else
    fail "G3: rc=$RC err=$FIND_ERR"
fi
teardown_tmp_gl

# --- G4 (mirror F7): closed_by primary wins over a stale marker MR.
setup_tmp_gl
GL_MOCK_CLOSED_BY="$GL_CB" GL_MOCK_MARKER="$GL_MK" run_find_gl 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "3" ] && [ "$FIND_MERGE_COMMIT" = "sha1230" ]; then
    pass "G4: gitlab closed_by primary wins over marker fallback"
else
    fail "G4: rc=$RC pr=$FIND_PR_NUMBER sha=$FIND_MERGE_COMMIT err=$FIND_ERR"
fi
teardown_tmp_gl

# --- G5 (gitlab edge): project path unresolvable → exit 1, glab never queried.
setup_tmp_gl
SHIM_PROJECT="" GL_MOCK_CLOSED_BY="$GL_CB" run_find_gl 42; RC=$?
if [ "$RC" -eq 1 ] && echo "$FIND_ERR" | grep -qi "could not resolve GitLab project" && [ ! -s "$GL_LOG" ]; then
    pass "G5: gitlab unresolvable project → exit 1, glab not called"
else
    fail "G5: rc=$RC err=$FIND_ERR gl_log=[$(cat "$GL_LOG" 2>/dev/null)]"
fi
teardown_tmp_gl

# --- G6 (gitlab edge): cross-repo --repo mismatch → exit 2, glab never queried.
setup_tmp_gl
GL_MOCK_CLOSED_BY="$GL_CB" run_find_gl --repo other/project 42; RC=$?
if [ "$RC" -eq 2 ] && echo "$FIND_ERR" | grep -qi "does not support cross-repo" && [ ! -s "$GL_LOG" ]; then
    pass "G6: gitlab cross-repo --repo mismatch → exit 2, glab not called"
else
    fail "G6: rc=$RC err=$FIND_ERR gl_log=[$(cat "$GL_LOG" 2>/dev/null)]"
fi
teardown_tmp_gl

# --- G7 (gitlab edge): --repo equal to the resolved project is accepted and the
# primary lookup still runs (proves the guard rejects only a MISMATCH).
setup_tmp_gl
GL_MOCK_CLOSED_BY="$GL_CB" run_find_gl --repo acme/widgets 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "3" ]; then
    pass "G7: gitlab --repo matching the project is accepted → PR 3"
else
    fail "G7: rc=$RC pr=$FIND_PR_NUMBER err=$FIND_ERR"
fi
teardown_tmp_gl

# --- G8 (mirror F6, ORTH): non-numeric N rejected BEFORE forge detection → exit
# 1, no shell injection, and glab is never invoked (numeric guard precedes forge).
setup_tmp_gl
GL_MOCK_CLOSED_BY="$GL_CB" run_with_timeout 15 bash "$FIND_SCRIPT" "42; touch /tmp/G8_INJECT" >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f /tmp/G8_INJECT ] && [ ! -s "$GL_LOG" ]; then
    pass "G8: gitlab non-numeric N → exit 1 before forge detection, glab not called"
else
    fail "G8: rc=$RC inject=$([ -f /tmp/G8_INJECT ] && echo yes || echo no) gl_log=[$(cat "$GL_LOG" 2>/dev/null)]"
    rm -f /tmp/G8_INJECT 2>/dev/null
fi
teardown_tmp_gl

# --- G9 (gitlab edge): glab API hard failure (non-zero exit, e.g. auth/network).
# The script wraps every glab call in `... 2>/dev/null) || VAR=""`, so a non-zero
# glab degrades to the same not-found path — exit 1 "no MR" — WITHOUT crashing
# under `set -uo pipefail`. glab MUST have been queried (log non-empty), which
# distinguishes this from G5 (unresolvable project → glab never called).
setup_tmp_gl
GL_MOCK_EXIT=1 GL_MOCK_CLOSED_BY="$GL_CB" GL_MOCK_MARKER="$GL_MK" run_find_gl 42; RC=$?
if [ "$RC" -eq 1 ] && echo "$FIND_ERR" | grep -qi "no MR" && [ -s "$GL_LOG" ]; then
    pass "G9: gitlab glab API failure (non-zero exit) → exit 1 (no MR), glab was queried"
else
    fail "G9: rc=$RC err=$FIND_ERR gl_log=[$(cat "$GL_LOG" 2>/dev/null)]"
fi
teardown_tmp_gl

# --- G10 (gitlab edge): nested-namespace project path (3+ segments) is URL-encoded
# so `/` → `%2F` before interpolation into `glab api projects/<path>/...`. Proves
# the script encodes subgroup paths correctly (a raw `/` would address the wrong
# REST endpoint). The primary closed_by lookup still resolves PR 3.
setup_tmp_gl
SHIM_PROJECT="group/sub/project" GL_MOCK_CLOSED_BY="$GL_CB" run_find_gl 42; RC=$?
if [ "$RC" -eq 0 ] && [ "$FIND_PR_NUMBER" = "3" ] && grep -q "projects/group%2Fsub%2Fproject/issues/42/closed_by" "$GL_LOG" 2>/dev/null; then
    pass "G10: gitlab subgroup project path encoded group%2Fsub%2Fproject → PR 3"
else
    fail "G10: rc=$RC pr=$FIND_PR_NUMBER err=$FIND_ERR gl_log=[$(cat "$GL_LOG" 2>/dev/null)]"
fi
teardown_tmp_gl

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
