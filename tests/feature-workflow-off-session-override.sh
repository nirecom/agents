#!/bin/bash
# tests/feature-workflow-off-session-override.sh
# Tests: hooks/lib/session-markers.js, hooks/workflow-mark.js
# Tags: workflow, sentinel, hook, bin, tests
#
# Integration tests for the session-scoped ENFORCE_WORKFLOW escape hatch.
#
# Feature contract:
#   - workflow-mark.js (PostToolUse) intercepts:
#       echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: <reason>>"
#     and writes a marker file:
#       <workflowDir>/<sessionId>.workflow-off
#     The marker JSON contains "set_at" and (optionally) "reason".
#   - hooks/lib/session-markers.js exports isWorkflowOff(sid) which returns
#     true iff <workflowDir>/<sid>.workflow-off exists and sid is well-formed.
#     Fail-closed on any error.
#   - The matching ON sentinel:
#       echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: <reason>>"
#     deletes the marker (per-session only).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_SCRIPT_ABS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
CASE_DIR="$AGENTS_DIR/tests/feature-workflow-off-session-override"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'eworkflow-sess-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
NEUTRAL_CWD=""
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE" "$NEUTRAL_CWD"' EXIT

# --- Fixture isolation (see rules/test/fixture-isolation.md) ---------------
# WORKFLOW_PLANS_DIR is pinned everywhere CLAUDE_WORKFLOW_DIR is pinned, so
# supervisor-emit never resolves the developer's real ~/.workflow-plans/.
FIXTURE_PLANS_DIR="$TMPDIR_BASE/fixture-plans"
FIXTURE_PROJECT_DIR="$TMPDIR_BASE/fixture-project"
mkdir -p "$FIXTURE_PLANS_DIR" "$FIXTURE_PROJECT_DIR"
git -C "$FIXTURE_PROJECT_DIR" init -q -b main 2>/dev/null || true
git -C "$FIXTURE_PROJECT_DIR" config core.hooksPath /dev/null 2>/dev/null || true
if command -v cygpath >/dev/null 2>&1; then
    FIXTURE_PLANS_DIR="$(cygpath -m "$FIXTURE_PLANS_DIR")"
    FIXTURE_PROJECT_DIR="$(cygpath -m "$FIXTURE_PROJECT_DIR")"
fi
export CLAUDE_PROJECT_DIR="$FIXTURE_PROJECT_DIR"

NEUTRAL_CWD="$(mktemp -d)"
cd "$NEUTRAL_CWD" || exit 1

# shellcheck source=/dev/null
. "$CASE_DIR/helpers.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/a-sentinel-off.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/b-session-markers-api.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/c-round-trip.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/sec-path-traversal.sh"


# ============================================================================
# Run all (wrap in 120s wall-clock timeout if available)
# ============================================================================

run_all() {
    # A: sentinel ingestion (OFF)
    test_A1_marker_created_on_sentinel
    test_A2_marker_with_reason
    test_A3_non_zero_exit_skips
    test_A4_env_file_fallback
    test_A5_no_session_id_hard_blocks
    test_A6_chained_sentinels_accepted
    test_A7_idempotent_marker_write
    # A8-A11: ENFORCE_WORKFLOW_ON sentinel
    test_A8_on_sentinel_deletes_marker
    test_A9_on_sentinel_no_marker_idempotent
    test_A10_on_sentinel_no_session_id
    test_A11_on_sentinel_session_isolation
    # A12-A13: bare-form rejection
    test_A12_bare_off_malformed
    test_A13_bare_on_malformed
    # A14-A15: transcript_path fallback (#461)
    test_A14_transcript_path_fallback
    test_A15_transcript_path_invalid_chars
    # B: hooks/lib/session-markers.js direct
    test_B1_isworkflowoff_true_when_marker_exists
    test_B2_isworkflowoff_false_when_no_marker
    test_B3_isworkflowoff_wrong_sid_returns_false
    test_B4_isworkflowoff_empty_sid_returns_false
    test_B5_isworkflowoff_traversal_sid_returns_false
    test_B6_isworkflowoff_failclosed_when_getworkflowdir_throws
    test_B7_notice_text_never_throws
    # C: round trip
    test_C1_round_trip_off_creates_and_off_returns_true
    test_C2_marker_removal_returns_false
    test_C3_off_on_round_trip_via_sentinels
    # SEC
    test_SEC1_path_traversal_rejected
    test_SEC2_shell_metachars_rejected
    test_SEC3_env_file_traversal_failclosed
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_WORKFLOW_OFF_TEST_INNER:-}" ]; then
        _WORKFLOW_OFF_TEST_INNER=1 timeout 120 bash "$_SCRIPT_ABS" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
