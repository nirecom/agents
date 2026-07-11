#!/bin/bash
# tests/feature-1207-warnings-escape-hatch.sh
# Tests: hooks/workflow-gate/review-tests-checker.js, hooks/lib/workflow-state/state-io.js
# Tags: review-tests, warnings-escape-hatch, warnings-accepted, token-preservation, scope:issue-specific
#
# Issue #1207 — WARNINGS escape hatch: after clearReviewTestsWarnings(), the
# gate must no longer block, but the existing token must be PRESERVED so the
# stale-token guard still fires if tests/ content changes post-acceptance.
#
# Current state: clearReviewTestsWarnings() does not exist in state-io.js.
# The gate (review-tests-checker.js) correctly blocks when warnings_summary is
# set (line 38-39), but there is no way to accept warnings and clear the field
# while keeping the token intact.
#
# EXPECTED:
#   Cases 18 (WARNINGS blocks gate) — PASSES now (existing behavior correct).
#   Cases 19-21 — FAIL until clearReviewTestsWarnings() is implemented.
#
# L3 gap (what this L2 test does NOT catch):
# - Whether WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED sentinel flows through the
#   full hook pipeline (workflow-mark.js PostToolUse → state-io.js) in a live
#   Claude Code session with a real session ID.
# - Whether the sentinel is blocked by the chain-boundary guard when chained
#   with another command (guard enforcement is in workflow-gate.js PreToolUse).
# Closest-to-action mitigation: sentinel regex coverage in the table-driven
# tests in feature-833-review-tests-sentinel-ssot.sh (section 3).

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER_JS="$AGENTS_DIR/hooks/workflow-gate/review-tests-checker.js"
STATE_IO_JS="$AGENTS_DIR/hooks/lib/workflow-state/state-io.js"
export AGENTS_CONFIG_DIR="$AGENTS_DIR"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

# ---------------------------------------------------------------------------
# Precondition gates
# ---------------------------------------------------------------------------
missing=()
[[ -f "$CHECKER_JS" ]]  || missing+=("hooks/workflow-gate/review-tests-checker.js")
[[ -f "$STATE_IO_JS" ]] || missing+=("hooks/lib/workflow-state/state-io.js")
if [[ "${#missing[@]}" -gt 0 ]]; then
    for m in "${missing[@]}"; do echo "FAIL: precondition missing — $m"; done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Windows-compatible tmpdir
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/eh1207.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow"
mkdir -p "$CLAUDE_WORKFLOW_DIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write a workflow state with review_tests status/token/warnings_summary.
write_review_tests_state() {
    local sid="$1" status="$2" token="$3" warnings_summary="$4"
    node -e '
        const fs = require("fs");
        const path = require("path");
        const [sid, status, token, ws] = process.argv.slice(1);
        const dir = process.env.CLAUDE_WORKFLOW_DIR;
        const step = { status, updated_at: new Date().toISOString() };
        if (token) step.token = token;
        if (ws) step.warnings_summary = ws;
        const state = {
            version: 1,
            session_id: sid,
            created_at: new Date().toISOString(),
            steps: { review_tests: step }
        };
        fs.writeFileSync(path.join(dir, sid + ".json"), JSON.stringify(state, null, 2));
    ' -- "$sid" "$status" "$token" "$warnings_summary"
}

# Read a field from review_tests step.
read_step_field() {
    local sid="$1" field="$2"
    node -e '
        const fs = require("fs");
        const path = require("path");
        const [sid, field] = process.argv.slice(1);
        const dir = process.env.CLAUDE_WORKFLOW_DIR;
        try {
            const state = JSON.parse(fs.readFileSync(path.join(dir, sid + ".json"), "utf8"));
            const val = (state.steps.review_tests || {})[field];
            process.stdout.write(val == null ? "NULL" : String(val));
        } catch (e) {
            process.stdout.write("ERROR:" + e.message);
        }
    ' -- "$sid" "$field"
}

# Call checkReviewTests() with a synthetic step object (no git repo needed).
# Returns the action: "skip", "block", or "not_handled".
call_checker() {
    local sid="$1" status="$2" token="$3" warnings_summary="$4" repo_dir="${5:-/nonexistent}"
    node -e '
        const path = require("path");
        const { checkReviewTests } = require(process.argv[1]);
        const [sid, status, token, ws, repoDir] = process.argv.slice(2);
        const stepState = { status };
        if (token) stepState.token = token;
        if (ws) stepState.warnings_summary = ws;
        const opts = {
            docsOnly: false,
            writeTestsEvidenceBypassed: false,
            repoDir,
            sessionId: sid
        };
        try {
            const result = checkReviewTests("review_tests", stepState, opts);
            process.stdout.write(result.action);
        } catch (e) {
            process.stdout.write("ERROR:" + e.message);
        }
    ' -- "$CHECKER_JS" "$sid" "$status" "$token" "$warnings_summary" "$repo_dir"
}

# Call clearReviewTestsWarnings() from state-io.js (planned new export).
call_clear_warnings() {
    local sid="$1"
    node -e '
        const path = require("path");
        const io = require(process.argv[1]);
        const sid = process.argv[2];
        if (typeof io.clearReviewTestsWarnings !== "function") {
            process.stdout.write("NOT_IMPLEMENTED");
            process.exit(0);
        }
        try {
            io.clearReviewTestsWarnings(sid);
            process.stdout.write("OK");
        } catch (e) {
            process.stdout.write("ERROR:" + e.message);
        }
    ' -- "$STATE_IO_JS" "$sid"
}

# ---------------------------------------------------------------------------
# Case 18 — WARNINGS state with token=T, warnings_summary set → gate blocks.
#   This is existing correct behavior (checker.js line 38-39). Should PASS now.
# ---------------------------------------------------------------------------
SID18="test-sid-1207-18"
write_review_tests_state "$SID18" "complete" "abc123def456" "token=abc123def456 warnings=2 INFO=1"
action18="$(call_checker "$SID18" "complete" "abc123def456" "token=abc123def456 warnings=2 INFO=1")"
if [[ "$action18" == "block" ]]; then
    pass "18: WARNINGS state + warnings_summary set → gate blocks (existing behavior correct)"
else
    fail "18: expected block, got [$action18]"
fi

# ---------------------------------------------------------------------------
# Case 19 — After clearReviewTestsWarnings() → state has token preserved,
#           warnings_summary=null.
#   EXPECTED: FAIL until clearReviewTestsWarnings() is implemented.
# ---------------------------------------------------------------------------
SID19="test-sid-1207-19"
write_review_tests_state "$SID19" "complete" "abc123def456" "token=abc123def456 warnings=2"
clear_result="$(call_clear_warnings "$SID19")"
if [[ "$clear_result" == "NOT_IMPLEMENTED" ]]; then
    fail "19: clearReviewTestsWarnings() is not yet implemented in state-io.js"
elif [[ "$clear_result" == "OK" ]]; then
    token_after="$(read_step_field "$SID19" "token")"
    ws_after="$(read_step_field "$SID19" "warnings_summary")"
    if [[ "$token_after" == "abc123def456" && "$ws_after" == "NULL" ]]; then
        pass "19: clearReviewTestsWarnings() preserves token and clears warnings_summary"
    else
        fail "19: after clear — token=[$token_after] (expected abc123def456), warnings_summary=[$ws_after] (expected NULL)"
    fi
else
    fail "19: clearReviewTestsWarnings() returned error: $clear_result"
fi

# ---------------------------------------------------------------------------
# Case 20 — Same staged token + no warnings_summary → gate does NOT block.
#   Simulates the state after clearReviewTestsWarnings(): complete, token
#   preserved, warnings_summary absent. We provide a repoDir with no staged
#   tests so computeStagedTestsToken returns null → gate skips.
#   EXPECTED: FAIL until clearReviewTestsWarnings() works (depends on case 19).
# ---------------------------------------------------------------------------
SID20="test-sid-1207-20"
# Write the state that clearReviewTestsWarnings should produce: complete, token
# set, no warnings_summary field.
write_review_tests_state "$SID20" "complete" "abc123def456" ""
action20="$(call_checker "$SID20" "complete" "abc123def456" "" "/nonexistent")"
if [[ "$action20" == "skip" ]]; then
    pass "20: complete + token + no warnings_summary + no staged tests → gate skips"
else
    fail "20: expected skip (gate approved), got [$action20]"
fi

# ---------------------------------------------------------------------------
# Case 21 (token-loss regression) — Implementation that drops the token when
#   clearing warnings causes the stale-token guard to later accept ANY staged
#   content (because storedToken is null → gate skips). This regression
#   undermines the anti-bypass protection.
#   We simulate by checking: after clearReviewTestsWarnings(), if the token
#   is null, a DIFFERENT staged token still produces a gate skip (false approval).
#   The test asserts that the token IS preserved — if not, it's a regression.
#   EXPECTED: FAIL until clearReviewTestsWarnings() preserves the token.
# ---------------------------------------------------------------------------
SID21="test-sid-1207-21"
write_review_tests_state "$SID21" "complete" "original-token-xyz" "token=original-token-xyz warnings=1"
clear_result21="$(call_clear_warnings "$SID21")"
if [[ "$clear_result21" == "NOT_IMPLEMENTED" ]]; then
    fail "21: token-loss regression guard — clearReviewTestsWarnings() not implemented"
elif [[ "$clear_result21" == "OK" ]]; then
    token_after21="$(read_step_field "$SID21" "token")"
    if [[ "$token_after21" == "original-token-xyz" ]]; then
        pass "21: token-loss guard — clearReviewTestsWarnings() preserves original token"
    elif [[ "$token_after21" == "NULL" || -z "$token_after21" ]]; then
        fail "21: REGRESSION — clearReviewTestsWarnings() dropped the token (stale-token guard now bypassed)"
    else
        fail "21: unexpected token after clear: [$token_after21]"
    fi
else
    fail "21: clearReviewTestsWarnings() returned error: $clear_result21"
fi

# ---------------------------------------------------------------------------
# Case 22 (C2) — End-to-end dispatch: WARNINGS_ACCEPTED sentinel flows through
#   workflow-mark.js dispatch and calls clearReviewTestsWarnings().
#
#   Dispatch path (from hooks/workflow-mark.js):
#     JSON stdin → isSentinel() filter → sentinelParts loop → reviewTestsHandler.handle()
#     (reviewTestsHandler must handle WARNINGS_ACCEPTED and call clearReviewTestsWarnings)
#
#   We simulate a PostToolUse event by feeding JSON to workflow-mark.js stdin,
#   then read the resulting state to verify warnings_summary was cleared and
#   token was preserved.
#
#   EXPECTED: FAIL until:
#     1. REVIEW_TESTS_WARNINGS_ACCEPTED_RE_DQ is added to sentinel-patterns.js
#     2. reviewTestsHandler handles the sentinel and calls clearReviewTestsWarnings()
#     3. clearReviewTestsWarnings() is implemented in state-io.js
# ---------------------------------------------------------------------------
WORKFLOW_MARK_JS="$AGENTS_DIR/hooks/workflow-mark.js"
SID22="test-sid-1207-22"
write_review_tests_state "$SID22" "complete" "tok22abc" "token=tok22abc warnings=3"

if [[ ! -f "$WORKFLOW_MARK_JS" ]]; then
    fail "22: precondition missing — hooks/workflow-mark.js"
else
    # Build a PostToolUse event JSON.
    event22=$(node -e '
        const sid = process.argv[1];
        process.stdout.write(JSON.stringify({
            tool_name: "Bash",
            session_id: sid,
            transcript_path: null,
            tool_input: {
                command: "echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: all 3 warnings reviewed and accepted>>\""
            },
            tool_response: { exit_code: 0, stdout: "" }
        }));
    ' "$SID22")

    dispatch_out=""
    dispatch_rc=0
    dispatch_out=$(echo "$event22" | "$RWT" 120 node "$WORKFLOW_MARK_JS" 2>&1) || dispatch_rc=$?

    # After dispatch: warnings_summary must be null, token must be preserved.
    tok22_after="$(read_step_field "$SID22" "token")"
    ws22_after="$(read_step_field "$SID22" "warnings_summary")"

    if [[ "$tok22_after" == "tok22abc" && "$ws22_after" == "NULL" ]]; then
        pass "22: WARNINGS_ACCEPTED dispatch — full wire: sentinel→dispatch→clearReviewTestsWarnings (token preserved, warnings cleared)"
    elif [[ "$ws22_after" != "NULL" ]]; then
        fail "22: dispatch did not clear warnings_summary (still [$ws22_after]); sentinel may not be registered or handler missing"
    elif [[ "$tok22_after" != "tok22abc" ]]; then
        fail "22: dispatch cleared warnings but DROPPED token (was [tok22abc], now [$tok22_after])"
    else
        fail "22: unexpected state after dispatch (tok=[$tok22_after] ws=[$ws22_after] rc=$dispatch_rc)"
    fi
fi

# ---------------------------------------------------------------------------
# Case 23 (C5) — clearReviewTestsWarnings() idempotency: second call is safe.
#   EXPECTED: FAIL until clearReviewTestsWarnings() is implemented.
# ---------------------------------------------------------------------------
SID23="test-sid-1207-23"
write_review_tests_state "$SID23" "complete" "idempotent-tok" "token=idempotent-tok warnings=1"
clear_r23a="$(call_clear_warnings "$SID23")"
clear_r23b="$(call_clear_warnings "$SID23")"
if [[ "$clear_r23a" == "NOT_IMPLEMENTED" || "$clear_r23b" == "NOT_IMPLEMENTED" ]]; then
    fail "23: clearReviewTestsWarnings() not implemented (idempotency cannot be tested)"
elif [[ "$clear_r23a" == "OK" && "$clear_r23b" == "OK" ]]; then
    tok23="$(read_step_field "$SID23" "token")"
    ws23="$(read_step_field "$SID23" "warnings_summary")"
    if [[ "$tok23" == "idempotent-tok" && "$ws23" == "NULL" ]]; then
        pass "23: clearReviewTestsWarnings() is idempotent (second call safe, token preserved)"
    else
        fail "23: after two calls — tok=[$tok23] ws=[$ws23]"
    fi
else
    fail "23: clearReviewTestsWarnings() returned errors: first=[$clear_r23a] second=[$clear_r23b]"
fi

# ---------------------------------------------------------------------------
# Case 24 (C5) — clearReviewTestsWarnings() on missing state file: no crash.
#   EXPECTED: FAIL until clearReviewTestsWarnings() is implemented.
# ---------------------------------------------------------------------------
SID24="test-sid-1207-24-no-state-file"
# Do NOT write a state file for SID24.
clear_r24="$(call_clear_warnings "$SID24")"
if [[ "$clear_r24" == "NOT_IMPLEMENTED" ]]; then
    fail "24: clearReviewTestsWarnings() not implemented (fail-open cannot be tested)"
elif [[ "$clear_r24" == "OK" || "$clear_r24" == "NOOP" ]]; then
    pass "24: clearReviewTestsWarnings() on missing state file → no crash (fail-open)"
elif echo "$clear_r24" | grep -qi "error"; then
    fail "24: clearReviewTestsWarnings() crashed on missing state file: $clear_r24"
else
    pass "24: clearReviewTestsWarnings() on missing state file → graceful (returned: $clear_r24)"
fi

# ---------------------------------------------------------------------------
# Case 25 (C5) — clearReviewTestsWarnings() with invalid sessionId → rejected.
#   Path traversal like ../../etc must be caught by assertValidSessionId().
#   EXPECTED: FAIL until clearReviewTestsWarnings() is implemented.
# ---------------------------------------------------------------------------
clear_r25="$(
    node -e '
        const io = require(process.argv[1]);
        if (typeof io.clearReviewTestsWarnings !== "function") {
            process.stdout.write("NOT_IMPLEMENTED"); process.exit(0);
        }
        try {
            io.clearReviewTestsWarnings("../../etc/passwd");
            process.stdout.write("NO_THROW");
        } catch (e) {
            process.stdout.write("THREW:" + e.message);
        }
    ' -- "$STATE_IO_JS" 2>/dev/null || echo "ERROR"
)"
if [[ "$clear_r25" == "NOT_IMPLEMENTED" ]]; then
    fail "25: clearReviewTestsWarnings() not implemented (path-traversal guard cannot be tested)"
elif echo "$clear_r25" | grep -q "^THREW:"; then
    pass "25: clearReviewTestsWarnings() rejects path-traversal sessionId (threw: ${clear_r25#THREW:})"
elif [[ "$clear_r25" == "NO_THROW" ]]; then
    fail "25: clearReviewTestsWarnings() accepted path-traversal sessionId without throwing"
else
    fail "25: unexpected result for path-traversal test: [$clear_r25]"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
