#!/bin/bash
# tests/feature-session-markers-isworktreeoff.sh
# Tests: hooks/lib/session-markers, hooks/lib/session-markers.js
# Tags: worktree, hook, bin, tests
#
# Unit test for hooks/lib/session-markers.js — isWorktreeOff() and
# worktreeOffNoticeText() functions (issue #550).
#
# TDD note: tests B and E will FAIL until session-markers.js exports
# isWorktreeOff / worktreeOffNoticeText.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'eisworktreeoff-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

fresh_workflow_dir() {
    local d="$TMPDIR_BASE/wf-$RANDOM-$$"
    mkdir -p "$d"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$d"
    else
        echo "$d"
    fi
}

# Call isWorktreeOff(sid) via node.
# Exit codes:
#   0 = function returned true
#   1 = function returned false (also: function not yet exported → treated as false,
#       matching fail-closed semantics)
#   3 = unexpected error (require failed, etc.)
call_is_worktree_off() {
    local wfdir="$1" sid="$2"
    run_with_timeout 20 env \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        node -e '
            try {
              const m = require(process.env.AGENTS_CONFIG_DIR + "/hooks/lib/session-markers");
              if (typeof m.isWorktreeOff !== "function") {
                // Not yet exported — semantically equivalent to "returns false"
                // (fail-closed). The B test distinguishes positive cases.
                process.exit(1);
              }
              process.exit(m.isWorktreeOff(process.argv[1]) ? 0 : 1);
            } catch (e) {
              process.stderr.write("err: " + e.message + "\n");
              process.exit(3);
            }
        ' "$sid"
    return $?
}

# Capture worktreeOffNoticeText(hookName, sid) output.
NOTICE_OUT=""
NOTICE_RC=0
call_notice_text() {
    local wfdir="$1" hookName="$2" sid="$3"
    NOTICE_RC=0
    NOTICE_OUT="$(run_with_timeout 20 env \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        node -e '
            try {
              const m = require(process.env.AGENTS_CONFIG_DIR + "/hooks/lib/session-markers");
              if (typeof m.worktreeOffNoticeText !== "function") { process.stderr.write("missing-fn\n"); process.exit(2); }
              const out = m.worktreeOffNoticeText(process.argv[1], process.argv[2]);
              if (typeof out !== "string") { process.stderr.write("not-string\n"); process.exit(3); }
              process.stdout.write(out);
              process.exit(0);
            } catch (e) {
              process.stderr.write("err: " + e.message + "\n");
              process.exit(4);
            }
        ' "$hookName" "$sid" 2>&1)" || NOTICE_RC=$?
}

# ----------------------------------------------------------------------------
test_A_marker_absent() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsess001"
    call_is_worktree_off "$wfdir" "$sid"
    local rc=$?
    if [ "$rc" = "1" ]; then
        pass "A: marker absent → isWorktreeOff returns false"
    else
        fail "A: expected rc=1 (false), got rc=$rc"
    fi
}

test_B_marker_present() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsess002"
    printf '{"set_at":"x"}' > "$wfdir/$sid.worktree-off"
    call_is_worktree_off "$wfdir" "$sid"
    local rc=$?
    if [ "$rc" = "0" ]; then
        pass "B: marker present → isWorktreeOff returns true"
    else
        fail "B: expected rc=0 (true), got rc=$rc (isWorktreeOff not yet exported?)"
    fi
}

test_C_traversal_sid() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local parent; parent="$(dirname "$wfdir")"
    printf '{"set_at":"x"}' > "$parent/evil.worktree-off"
    call_is_worktree_off "$wfdir" "../evil"
    local rc=$?
    rm -f "$parent/evil.worktree-off" 2>/dev/null || true
    if [ "$rc" = "1" ]; then
        pass "C: traversal sid ../evil → returns false (SID_RE blocks path traversal)"
    else
        fail "C: expected rc=1 (false), got rc=$rc — traversal allowed!"
    fi
}

test_D1_empty_sid() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    call_is_worktree_off "$wfdir" ""
    local rc=$?
    if [ "$rc" = "1" ]; then
        pass "D1: empty sid → returns false"
    else
        fail "D1: expected rc=1 (false), got rc=$rc"
    fi
}

test_D2_slash_sid() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    call_is_worktree_off "$wfdir" "abc/def"
    local rc=$?
    if [ "$rc" = "1" ]; then
        pass "D2: sid containing slash → returns false"
    else
        fail "D2: expected rc=1 (false), got rc=$rc"
    fi
}

test_E_notice_text() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsess005"
    call_notice_text "$wfdir" "enforce-worktree" "$sid"
    if [ "$NOTICE_RC" != "0" ]; then
        fail "E: notice call failed rc=$NOTICE_RC (out: $NOTICE_OUT) — worktreeOffNoticeText not yet exported?"
        return
    fi
    local ok=1
    echo "$NOTICE_OUT" | grep -q "enforce-worktree" || ok=0
    echo "$NOTICE_OUT" | grep -q "$sid.worktree-off" || ok=0
    echo "$NOTICE_OUT" | grep -q "Delete the marker" || ok=0
    if [ "$ok" = "1" ]; then
        pass "E: notice text contains hookName, marker path, and 'Delete the marker'"
    else
        fail "E: notice text missing one of (hookName/marker-path/'Delete the marker'): $NOTICE_OUT"
    fi
}

test_F_notice_does_not_throw_on_bad_workflow_dir() {
    local sid="testsess006"
    # Set CLAUDE_WORKFLOW_DIR to a value that won't crash join() but is invalid.
    # The contract is: worktreeOffNoticeText NEVER throws — returns a string.
    NOTICE_RC=0
    NOTICE_OUT="$(run_with_timeout 20 env \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=" \
        node -e '
            try {
              const m = require(process.env.AGENTS_CONFIG_DIR + "/hooks/lib/session-markers");
              if (typeof m.worktreeOffNoticeText !== "function") { process.stderr.write("missing-fn\n"); process.exit(2); }
              const out = m.worktreeOffNoticeText("enforce-worktree", process.argv[1]);
              if (typeof out !== "string") { process.stderr.write("not-string\n"); process.exit(3); }
              process.stdout.write(out);
              process.exit(0);
            } catch (e) {
              process.stderr.write("THREW: " + e.message + "\n");
              process.exit(4);
            }
        ' "$sid" 2>&1)" || NOTICE_RC=$?
    if [ "$NOTICE_RC" = "0" ] && [ -n "$NOTICE_OUT" ]; then
        pass "F: worktreeOffNoticeText does not throw with empty CLAUDE_WORKFLOW_DIR"
    elif [ "$NOTICE_RC" = "2" ]; then
        fail "F: worktreeOffNoticeText not yet exported"
    else
        fail "F: expected rc=0 with string output, got rc=$NOTICE_RC (out: $NOTICE_OUT)"
    fi
}

run_all() {
    test_A_marker_absent
    test_B_marker_present
    test_C_traversal_sid
    test_D1_empty_sid
    test_D2_slash_sid
    test_E_notice_text
    test_F_notice_does_not_throw_on_bad_workflow_dir
}

# Outer timeout guard
if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_ISWORKTREEOFF_INNER:-}" ]; then
        _ISWORKTREEOFF_INNER=1 timeout 180 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
