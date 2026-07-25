#!/usr/bin/env bash
# tests/fix-924-warnings-summary-wsid-scope.sh
# Tests: hooks/workflow-gate/review-tests-checker.js
# Tags: workflow-gate, review-tests, wsid-scope, warnings-summary, scope:issue-specific, pwsh-not-required, TL1
#
# #924: the warnings_summary block in checkReviewTests() (L37-40) fires before any
# wsid check, so a stale warnings_summary from a PRIOR wsid wrongly blocks the
# current wsid's commit. Fix: wsid-scope the warnings_summary check (mirror of the
# token path L50-61) so stale prior-wsid warnings fall through instead of blocking.
#
# Isolation (detail plan §#924): only the stagedToken==null case (no staged tests)
# is #924's responsibility. staged-tests + stale-wsid is the token path's job
# (PR #963, out of scope). Fixtures use a non-git repoDir so computeStagedTestsToken
# returns null and the token path resolves to skip — isolating warnings_summary as
# the sole block source.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
CHECKER_NODE="$_AGENTS_DIR_NODE/hooks/workflow-gate/review-tests-checker.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wsid924'; }

# run_checker <stepState-json> <resolved-wsid> → prints checkReviewTests result JSON.
# The non-git tmp CWD + tmp plansDir makes resolveWorkflowSessionId() deterministic:
#   Priority 1 (WORKTREE_NOTES) absent, git-based priorities fail (non-git dir),
#   Priority 2 (CLAUDE_CODE_SESSION_ID + <wsid>-intent.md artifact) resolves to $2.
run_checker() {
    local step_state="$1" resolved_wsid="$2"
    local cwddir plansdir out
    cwddir=$(make_tmp)   # non-git → computeStagedTestsToken null, git-based wsid priorities fail
    plansdir=$(make_tmp)
    : > "$plansdir/${resolved_wsid}-intent.md"   # artifact so Priority 2 accepts the sid
    local plansdir_node cwddir_node
    if command -v cygpath >/dev/null 2>&1; then
        plansdir_node="$(cygpath -m "$plansdir")"
        cwddir_node="$(cygpath -m "$cwddir")"
    else
        plansdir_node="$plansdir"; cwddir_node="$cwddir"
    fi
    out=$(cd "$cwddir" && WORKFLOW_PLANS_DIR="$plansdir_node" CLAUDE_CODE_SESSION_ID="$resolved_wsid" \
        "$RWT" 20 node -e "
const { checkReviewTests } = require('$CHECKER_NODE');
const stepState = JSON.parse(process.argv[1]);
const opts = { docsOnly: false, writeTestsEvidenceBypassed: false, repoDir: '$cwddir_node', sessionId: 'cc-sid-924' };
process.stdout.write(JSON.stringify(checkReviewTests('review_tests', stepState, opts)));
" "$step_state" 2>/dev/null)
    rm -rf "$cwddir" "$plansdir" 2>/dev/null || true
    printf '%s' "$out"
}

if [ ! -f "$AGENTS_DIR/hooks/workflow-gate/review-tests-checker.js" ]; then
    fail "checker file missing (harness error)"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi

# --- (a) stale prior-wsid warnings + no staged tests → skip (RED until fix) ---
# storedWsid=old, resolveWorkflowSessionId()=new → stale → warnings block must be
# suppressed → token path (stagedToken==null) returns skip.
res_a=$(run_checker '{"status":"complete","warnings_summary":"warnings=2","wsid":"20260722-oldwsid"}' "20260722-newwsid")
if echo "$res_a" | grep -q '"action":"skip"'; then
    pass "(a) stale prior-wsid warnings_summary + no staged tests → skip"
else
    fail "(a) RED-EXPECTED (fix absent): stale prior-wsid warnings still blocks; got: ${res_a:-<empty>}"
fi

# --- (b) warnings + wsid matches current → block preserved (GREEN now & after) ---
# CPR-5 counterpart: fix must NOT over-permit when the warnings belong to the
# CURRENT wsid. storedWsid == resolveWorkflowSessionId() → still block.
res_b=$(run_checker '{"status":"complete","warnings_summary":"warnings=2","wsid":"20260722-samewsid"}' "20260722-samewsid")
if echo "$res_b" | grep -q '"reason":"warnings-pending"'; then
    pass "(b) current-wsid warnings_summary → block warnings-pending preserved"
else
    fail "(b) current-wsid warnings must still block warnings-pending; got: ${res_b:-<empty>}"
fi

# --- (c) warnings + storedWsid absent (legacy) → block preserved (GREEN now & after) ---
res_c=$(run_checker '{"status":"complete","warnings_summary":"warnings=2"}' "20260722-anywsid")
if echo "$res_c" | grep -q '"reason":"warnings-pending"'; then
    pass "(c) legacy state (no wsid) warnings_summary → block warnings-pending preserved"
else
    fail "(c) legacy-state warnings must still block warnings-pending; got: ${res_c:-<empty>}"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
