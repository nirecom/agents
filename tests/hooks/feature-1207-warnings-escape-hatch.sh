#!/bin/bash
# tests/hooks/feature-1207-warnings-escape-hatch.sh
# Tests: hooks/workflow-gate/review-tests-checker.js, hooks/workflow-state/state-io.js
# Tags: review-tests, warnings-escape-hatch, warnings-accepted, token-preservation, manifest-preservation, scope:issue-specific
# #1207: after clearReviewTestsWarnings(), gate must no longer block, but
# review_scope_manifest must be PRESERVED so the stale-fingerprint guard still fires
# on scope change. Cases 19-25 FAIL until clearReviewTestsWarnings() is implemented.
# L3 gap: full hook pipeline (workflow-mark.js PostToolUse) needs a real session.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER_JS="$AGENTS_DIR/hooks/workflow-gate/review-tests-checker.js"
STATE_IO_JS="$AGENTS_DIR/hooks/workflow-state/state-io.js"
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
[[ -f "$STATE_IO_JS" ]] || missing+=("hooks/workflow-state/state-io.js")
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

# Plans-dir isolation (#1799): supervisor-emit must never write into the
# developer's real ~/.workflow-plans/. Pinned alongside CLAUDE_WORKFLOW_DIR.
WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
export WORKFLOW_PLANS_DIR

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write a workflow state with review_tests status/review_scope_manifest/warnings_summary.
write_review_tests_state() {
    local sid="$1" status="$2" manifest="$3" warnings_summary="$4"
    node -e '
        const fs = require("fs");
        const path = require("path");
        const [sid, status, manifest, ws] = process.argv.slice(1);
        const dir = process.env.CLAUDE_WORKFLOW_DIR;
        const step = { status, updated_at: new Date().toISOString() };
        if (manifest) {
            try { step.review_scope_manifest = JSON.parse(manifest); }
            catch (e) { step.review_scope_manifest = manifest; }
        }
        if (ws) step.warnings_summary = ws;
        const state = {
            version: 1,
            session_id: sid,
            created_at: new Date().toISOString(),
            steps: { review_tests: step }
        };
        fs.writeFileSync(path.join(dir, sid + ".json"), JSON.stringify(state, null, 2));
    ' -- "$sid" "$status" "$manifest" "$warnings_summary"
}

# Read a field from review_tests step. Returns "NULL" if absent, JSON string if object.
read_step_field() {
    local sid="$1" field="$2"
    # readState folds the event stream a state-io write leaves behind.
    node -e '
        const [io, sid, field] = process.argv.slice(1);
        try {
            const state = require(io).readState(sid) || {};
            const val = ((state.steps || {}).review_tests || {})[field];
            if (val == null) { process.stdout.write("NULL"); }
            else if (typeof val === "object") { process.stdout.write(JSON.stringify(val)); }
            else { process.stdout.write(String(val)); }
        } catch (e) {
            process.stdout.write("ERROR:" + e.message);
        }
    ' -- "$STATE_IO_JS" "$sid" "$field"
}

# Call checkReviewTests() with a synthetic step object (no git repo needed).
# Returns the action: "skip", "block", or "not_handled".
call_checker() {
    local sid="$1" status="$2" manifest="$3" warnings_summary="$4" repo_dir="${5:-/nonexistent}"
    node -e '
        const path = require("path");
        const { checkReviewTests } = require(process.argv[1]);
        const [sid, status, manifest, ws, repoDir] = process.argv.slice(2);
        const stepState = { status };
        if (manifest) {
            try { stepState.review_scope_manifest = JSON.parse(manifest); }
            catch (e) { stepState.review_scope_manifest = manifest; }
        }
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
    ' -- "$CHECKER_JS" "$sid" "$status" "$manifest" "$warnings_summary" "$repo_dir"
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

# Fake manifest JSON for test fixtures (minimal valid manifest).
FAKE_MANIFEST='{"v":1,"files":{"tests/fake.sh":"abc123def456789012"}}'

# ---------------------------------------------------------------------------
# Case 18 — WARNINGS state with manifest+warnings_summary set → gate blocks.
#   This is existing correct behavior (checker.js line 38-39). Should PASS now.
# ---------------------------------------------------------------------------
SID18="test-sid-1207-18"
write_review_tests_state "$SID18" "complete" "$FAKE_MANIFEST" "fingerprint=abc123def456 warnings=2 INFO=1"
action18="$(call_checker "$SID18" "complete" "$FAKE_MANIFEST" "fingerprint=abc123def456 warnings=2 INFO=1")"
if [[ "$action18" == "block" ]]; then
    pass "18: WARNINGS state + warnings_summary set → gate blocks (existing behavior correct)"
else
    fail "18: expected block, got [$action18]"
fi

# ---------------------------------------------------------------------------
# Case 19 — After clearReviewTestsWarnings() → review_scope_manifest preserved,
#           warnings_summary=null.
#   EXPECTED: FAIL until clearReviewTestsWarnings() is implemented.
# ---------------------------------------------------------------------------
SID19="test-sid-1207-19"
write_review_tests_state "$SID19" "complete" "$FAKE_MANIFEST" "fingerprint=abc123def456 warnings=2"
clear_result="$(call_clear_warnings "$SID19")"
if [[ "$clear_result" == "NOT_IMPLEMENTED" ]]; then
    fail "19: clearReviewTestsWarnings() is not yet implemented in state-io.js"
elif [[ "$clear_result" == "OK" ]]; then
    manifest_after="$(read_step_field "$SID19" "review_scope_manifest")"
    ws_after="$(read_step_field "$SID19" "warnings_summary")"
    if [[ "$manifest_after" != "NULL" && "$ws_after" == "NULL" ]]; then
        pass "19: clearReviewTestsWarnings() preserves review_scope_manifest and clears warnings_summary"
    else
        fail "19: after clear — manifest=[$manifest_after] (expected non-NULL), warnings_summary=[$ws_after] (expected NULL)"
    fi
else
    fail "19: clearReviewTestsWarnings() returned error: $clear_result"
fi

# ---------------------------------------------------------------------------
# Case 20 — Same staged manifest + no warnings_summary → gate does NOT block.
#   Simulates the state after clearReviewTestsWarnings(): complete, manifest
#   preserved, warnings_summary absent. A real fixture repo stages the same
#   tests/fake.sh the manifest records, so the fingerprint matches — an
#   unreadable repoDir would fail closed (fingerprint-unavailable) instead.
# ---------------------------------------------------------------------------
REPO20="$TMPDIR_BASE/repo20"
mkdir -p "$REPO20/tests"
git -C "$REPO20" init -q
git -C "$REPO20" config core.hooksPath /dev/null
git -C "$REPO20" config user.email t@test.com
git -C "$REPO20" config user.name T
printf 'seed\n' > "$REPO20/README.md"
git -C "$REPO20" add README.md
git -C "$REPO20" commit -qm init
printf 'echo fake\n' > "$REPO20/tests/fake.sh"
git -C "$REPO20" add tests/fake.sh
OID20="$(git -C "$REPO20" rev-parse :tests/fake.sh)"
MANIFEST20="{\"v\":1,\"files\":{\"tests/fake.sh\":\"$OID20\"}}"
REPO20_N="$REPO20"
command -v cygpath >/dev/null 2>&1 && REPO20_N="$(cygpath -m "$REPO20")"
SID20="test-sid-1207-20"
write_review_tests_state "$SID20" "complete" "$MANIFEST20" ""
action20="$(call_checker "$SID20" "complete" "$MANIFEST20" "" "$REPO20_N")"
if [[ "$action20" == "skip" ]]; then
    pass "20: complete + manifest matching staged set + no warnings_summary → gate skips"
else
    fail "20: expected skip (gate approved), got [$action20]"
fi

# ---------------------------------------------------------------------------
# Case 21 (manifest-loss regression) — Implementation that drops the manifest
#   when clearing warnings causes the stale-fingerprint guard to accept ANY staged
#   content (because storedManifest is null → gate skips). Test asserts manifest IS preserved.
#   EXPECTED: FAIL until clearReviewTestsWarnings() preserves review_scope_manifest.
# ---------------------------------------------------------------------------
SID21="test-sid-1207-21"
write_review_tests_state "$SID21" "complete" "$FAKE_MANIFEST" "fingerprint=original warnings=1"
clear_result21="$(call_clear_warnings "$SID21")"
if [[ "$clear_result21" == "NOT_IMPLEMENTED" ]]; then
    fail "21: manifest-loss regression guard — clearReviewTestsWarnings() not implemented"
elif [[ "$clear_result21" == "OK" ]]; then
    manifest_after21="$(read_step_field "$SID21" "review_scope_manifest")"
    if [[ "$manifest_after21" != "NULL" && -n "$manifest_after21" ]]; then
        pass "21: manifest-loss guard — clearReviewTestsWarnings() preserves review_scope_manifest"
    elif [[ "$manifest_after21" == "NULL" || -z "$manifest_after21" ]]; then
        fail "21: REGRESSION — clearReviewTestsWarnings() dropped review_scope_manifest (stale-fingerprint guard now bypassed)"
    else
        fail "21: unexpected manifest after clear: [$manifest_after21]"
    fi
else
    fail "21: clearReviewTestsWarnings() returned error: $clear_result21"
fi

# ---------------------------------------------------------------------------
# Case 22 (C2) — WARNINGS_ACCEPTED sentinel dispatched → manifest preserved,
# warnings cleared. EXPECTED: FAIL until REVIEW_TESTS_WARNINGS_ACCEPTED_RE_DQ
# added, reviewTestsHandler handles it, clearReviewTestsWarnings() implemented.
# ---------------------------------------------------------------------------
WORKFLOW_MARK_JS="$AGENTS_DIR/hooks/workflow-mark.js"
SID22="test-sid-1207-22"
write_review_tests_state "$SID22" "complete" "$FAKE_MANIFEST" "fingerprint=tok22abc warnings=3"

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

    # After dispatch: warnings_summary must be null, review_scope_manifest must be preserved.
    manifest22_after="$(read_step_field "$SID22" "review_scope_manifest")"
    ws22_after="$(read_step_field "$SID22" "warnings_summary")"

    if [[ "$manifest22_after" != "NULL" && "$ws22_after" == "NULL" ]]; then
        pass "22: WARNINGS_ACCEPTED dispatch — full wire: sentinel→dispatch→clearReviewTestsWarnings (manifest preserved, warnings cleared)"
    elif [[ "$ws22_after" != "NULL" ]]; then
        fail "22: dispatch did not clear warnings_summary (still [$ws22_after]); sentinel may not be registered or handler missing"
    elif [[ "$manifest22_after" == "NULL" ]]; then
        fail "22: dispatch cleared warnings but DROPPED review_scope_manifest (stale-fingerprint guard bypassed)"
    else
        fail "22: unexpected state after dispatch (manifest=[$manifest22_after] ws=[$ws22_after] rc=$dispatch_rc)"
    fi
fi

# ---------------------------------------------------------------------------
# Case 23 (C5) — clearReviewTestsWarnings() idempotency: second call is safe.
#   EXPECTED: FAIL until clearReviewTestsWarnings() is implemented.
# ---------------------------------------------------------------------------
SID23="test-sid-1207-23"
write_review_tests_state "$SID23" "complete" "$FAKE_MANIFEST" "fingerprint=idempotent warnings=1"
clear_r23a="$(call_clear_warnings "$SID23")"
clear_r23b="$(call_clear_warnings "$SID23")"
if [[ "$clear_r23a" == "NOT_IMPLEMENTED" || "$clear_r23b" == "NOT_IMPLEMENTED" ]]; then
    fail "23: clearReviewTestsWarnings() not implemented (idempotency cannot be tested)"
elif [[ "$clear_r23a" == "OK" && "$clear_r23b" == "OK" ]]; then
    manifest23="$(read_step_field "$SID23" "review_scope_manifest")"
    ws23="$(read_step_field "$SID23" "warnings_summary")"
    if [[ "$manifest23" != "NULL" && "$ws23" == "NULL" ]]; then
        pass "23: clearReviewTestsWarnings() is idempotent (second call safe, manifest preserved)"
    else
        fail "23: after two calls — manifest=[$manifest23] ws=[$ws23]"
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
