#!/usr/bin/env bash
# tests/feature-workflow-off-bypass-block-history-direct.sh
# Tests: hooks/block-history-direct.js
# Tags: hook, workflow-off, append-only, docs, marker, TL2, scope:common
#
# Issue #1725 — hooks/block-history-direct.js must approve (instead of block) when
# a protected-path/command hit occurs AND the calling session's WORKFLOW_OFF marker
# (<workflowDir>/<sid>.workflow-off) exists. The marker is shared by the normal
# WORKFLOW_ENFORCE_WORKFLOW_OFF sentinel and the WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY
# sentinel — no new marker is introduced.
#
# Contract:
#   - No marker → protected hit still blocks (baseline regression, both lanes).
#   - Marker present → protected hit approves (tool-write lane AND shell lane).
#   - Marker present → stderr carries a notice naming the hook and the marker.
#   - No hit → approve with NO bypass notice (marker check runs only after a hit).
#   - Unresolvable / traversal / missing sid → no bypass, block stands (fail-closed).
#   - Malformed stdin → approve, exit 0 (pre-existing fail-open, must not regress).
#
# TDD note (fail-before-fix, fix/* branch): every "marker present → approve" case
# below FAILS against the current unfixed hook. A01/A02/D02/E01 pass both before
# and after the fix.
#
# TL3 gap (what this test does NOT catch):
# - Whether Claude Code actually dispatches the PreToolUse event to this hook in a
#   live session, and whether the sid it passes matches the marker the sentinel wrote.
# - Whether the stderr notice actually surfaces to the model/user in a real session.
# - Whether the WORKFLOW_OFF sentinel emission path really creates the marker this
#   hook reads (cross-hook wiring across a real session lifetime).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    REPO_DIR_NODE="$(cygpath -m "$REPO_DIR")"
else
    REPO_DIR_NODE="$REPO_DIR"
fi
HOOK="$REPO_DIR_NODE/hooks/block-history-direct.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if [ -x "$REPO_DIR/bin/run-with-timeout.sh" ]; then
        "$REPO_DIR/bin/run-with-timeout.sh" "$secs" "$@"
    elif command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$want got=$got"; fi
}

if [ ! -f "$REPO_DIR/hooks/block-history-direct.js" ]; then
    fail "precondition" "hook not found at $REPO_DIR/hooks/block-history-direct.js"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

fresh_workflow_dir() {
    local d="$TMPDIR_BASE/wf-$RANDOM-$$-${1:-x}"
    mkdir -p "$d"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$d"
    else
        echo "$d"
    fi
}

write_marker_file() {
    local wfdir="$1" sid="$2"
    printf '{"set_at":"2026-01-01T00:00:00Z"}\n' > "$wfdir/$sid.workflow-off"
}

json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

# Payload builders — sid variants are separate builders so an absent session_id
# key is genuinely absent (not an empty string).
payload_file() {
    local sid="$1" tool="$2" fp="$3"
    printf '{"session_id":%s,"tool_name":%s,"tool_input":{"file_path":%s}}' \
        "$(json_quote "$sid")" "$(json_quote "$tool")" "$(json_quote "$fp")"
}
payload_file_no_sid() {
    local tool="$1" fp="$2"
    printf '{"tool_name":%s,"tool_input":{"file_path":%s}}' \
        "$(json_quote "$tool")" "$(json_quote "$fp")"
}
payload_cmd() {
    local sid="$1" tool="$2" cmd="$3"
    printf '{"session_id":%s,"tool_name":%s,"tool_input":{"command":%s}}' \
        "$(json_quote "$sid")" "$(json_quote "$tool")" "$(json_quote "$cmd")"
}

# run_hook <payload> <wfdir> — sets HOOK_OUT (stdout), HOOK_ERR (stderr), HOOK_RC.
# CLAUDE_WORKFLOW_DIR is pinned to an isolated temp dir and every ambient
# session-identifying env var is stripped, so the real session's WORKFLOW_OFF
# marker can never leak into a verdict here.
HOOK_OUT=""
HOOK_ERR=""
HOOK_RC=0
run_hook() {
    local payload="$1" wfdir="$2"
    local errfile="$TMPDIR_BASE/stderr.$$"
    HOOK_RC=0
    HOOK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$REPO_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        node "$HOOK" 2>"$errfile")" || HOOK_RC=$?
    HOOK_ERR="$(cat "$errfile" 2>/dev/null)"
    rm -f "$errfile"
}

# verdict — "approve" | "block" | "other", from HOOK_OUT only (stderr excluded).
verdict() {
    case "$HOOK_OUT" in
        *'"decision":"block"'*)   printf 'block' ;;
        *'"decision":"approve"'*) printf 'approve' ;;
        *)                        printf 'other' ;;
    esac
}

SID="testsession123"

echo "=== A: baseline — no marker, protected hit still blocks ==="

test_A01() {
    local wfdir; wfdir="$(fresh_workflow_dir a01)"
    run_hook "$(payload_file "$SID" Edit "docs/history/2026.md")" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then fail "A01-no-marker-edit-blocks" "hook rc=$HOOK_RC err=$HOOK_ERR"; return; fi
    assert_eq "A01-no-marker-edit-blocks" "block" "$(verdict)"
}

test_A02() {
    local wfdir; wfdir="$(fresh_workflow_dir a02)"
    run_hook "$(payload_cmd "$SID" Bash 'echo x >> docs/history.md')" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then fail "A02-no-marker-bash-blocks" "hook rc=$HOOK_RC err=$HOOK_ERR"; return; fi
    assert_eq "A02-no-marker-bash-blocks" "block" "$(verdict)"
}

echo ""

test_A01
test_A02

echo ""
echo "=== B: marker present — protected hit approves (both lanes) ==="

test_B01() {
    local wfdir; wfdir="$(fresh_workflow_dir b01)"
    write_marker_file "$wfdir" "$SID"
    run_hook "$(payload_file "$SID" Edit "docs/history/2026.md")" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then fail "B01-marker-edit-approves" "hook rc=$HOOK_RC err=$HOOK_ERR"; return; fi
    assert_eq "B01-marker-edit-approves" "approve" "$(verdict)"
}

test_B02() {
    local wfdir; wfdir="$(fresh_workflow_dir b02)"
    write_marker_file "$wfdir" "$SID"
    run_hook "$(payload_file "$SID" Write "CHANGELOG.md")" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then fail "B02-marker-write-changelog-approves" "hook rc=$HOOK_RC err=$HOOK_ERR"; return; fi
    assert_eq "B02-marker-write-changelog-approves" "approve" "$(verdict)"
}

test_B03() {
    local wfdir; wfdir="$(fresh_workflow_dir b03)"
    write_marker_file "$wfdir" "$SID"
    run_hook "$(payload_cmd "$SID" Bash 'echo x >> docs/history.md')" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then fail "B03-marker-bash-approves" "hook rc=$HOOK_RC err=$HOOK_ERR"; return; fi
    assert_eq "B03-marker-bash-approves" "approve" "$(verdict)"
}

test_B04() {
    local wfdir; wfdir="$(fresh_workflow_dir b04)"
    write_marker_file "$wfdir" "$SID"
    run_hook "$(payload_cmd "$SID" runCommands 'tee changelog/2026.md < a.md')" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then fail "B04-marker-runcommands-tee-approves" "hook rc=$HOOK_RC err=$HOOK_ERR"; return; fi
    assert_eq "B04-marker-runcommands-tee-approves" "approve" "$(verdict)"
}

test_B05() {
    local wfdir; wfdir="$(fresh_workflow_dir b05)"
    write_marker_file "$wfdir" "$SID"
    local p; p="$(payload_file "$SID" Edit "docs/history/2026.md")"
    run_hook "$p" "$wfdir"; local v1; v1="$(verdict)"; local rc1="$HOOK_RC"
    run_hook "$p" "$wfdir"; local v2; v2="$(verdict)"; local rc2="$HOOK_RC"
    if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ]; then
        fail "B05-idempotent-double-call" "hook rc1=$rc1 rc2=$rc2"; return
    fi
    assert_eq "B05-idempotent-double-call" "approve approve" "$v1 $v2"
    # The marker must survive — the bypass is not one-shot-consuming.
    if [ -f "$(cygpath -u "$wfdir" 2>/dev/null || echo "$wfdir")/$SID.workflow-off" ]; then
        pass "B05b-marker-not-consumed"
    else
        fail "B05b-marker-not-consumed" "marker file was deleted by the hook"
    fi
}

test_B01
test_B02
test_B03
test_B04
test_B05

echo ""
echo "=== C: sid resolution must be fail-closed ==="

test_C01() {
    local wfdir; wfdir="$(fresh_workflow_dir c01)"
    local wfdir_fs="$TMPDIR_BASE"
    # Plant a marker in the PARENT dir at the path `../evil` would resolve to.
    printf '{"set_at":"x"}\n' > "$wfdir_fs/evil.workflow-off"
    run_hook "$(payload_file "../evil" Edit "docs/history/2026.md")" "$wfdir"
    rm -f "$wfdir_fs/evil.workflow-off"
    if [ "$HOOK_RC" -ne 0 ]; then fail "C01-traversal-sid-blocks" "hook rc=$HOOK_RC err=$HOOK_ERR"; return; fi
    assert_eq "C01-traversal-sid-blocks" "block" "$(verdict)"
}

test_C02() {
    local wfdir; wfdir="$(fresh_workflow_dir c02)"
    run_hook "$(payload_file_no_sid Edit "docs/history/2026.md")" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then fail "C02-missing-session-id-blocks" "hook rc=$HOOK_RC err=$HOOK_ERR"; return; fi
    assert_eq "C02-missing-session-id-blocks" "block" "$(verdict)"
}

test_C03() {
    local wfdir; wfdir="$(fresh_workflow_dir c03)"
    write_marker_file "$wfdir" "$SID"
    run_hook "$(payload_file "" Edit "docs/history/2026.md")" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then fail "C03-empty-session-id-blocks" "hook rc=$HOOK_RC err=$HOOK_ERR"; return; fi
    assert_eq "C03-empty-session-id-blocks" "block" "$(verdict)"
}

test_C01
test_C02
test_C03

test_G01() {
    local wfdir; wfdir="$(fresh_workflow_dir g01)"
    # A DIFFERENT session's marker exists; the requesting session has none of its own.
    write_marker_file "$wfdir" "othersession999"
    run_hook "$(payload_file "$SID" Edit "docs/history/2026.md")" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then fail "G01-wrong-session-marker-blocks" "hook rc=$HOOK_RC err=$HOOK_ERR"; return; fi
    assert_eq "G01-wrong-session-marker-blocks" "block" "$(verdict)"
}

test_G01

echo ""
echo "=== D: stderr notice — present on bypass, absent without a hit ==="

test_D01() {
    local wfdir; wfdir="$(fresh_workflow_dir d01)"
    write_marker_file "$wfdir" "$SID"
    run_hook "$(payload_file "$SID" Edit "docs/history/2026.md")" "$wfdir"
    local ok=1
    case "$HOOK_ERR" in *block-history-direct*) ;; *) ok=0 ;; esac
    case "$HOOK_ERR" in *.workflow-off*) ;; *) ok=0 ;; esac
    if [ "$ok" = "1" ]; then
        pass "D01-bypass-notice-on-stderr"
    else
        fail "D01-bypass-notice-on-stderr" "stderr lacks 'block-history-direct' and/or '.workflow-off': [$HOOK_ERR]"
    fi
}

test_D02() {
    local wfdir; wfdir="$(fresh_workflow_dir d02)"
    write_marker_file "$wfdir" "$SID"
    run_hook "$(payload_file "$SID" Edit "docs/architecture.md")" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then fail "D02-non-protected-path-silent-approve" "hook rc=$HOOK_RC err=$HOOK_ERR"; return; fi
    local v; v="$(verdict)"
    local noisy=0
    case "$HOOK_ERR" in *workflow-off*|*WORKFLOW*|*block-history-direct*) noisy=1 ;; esac
    if [ "$v" = "approve" ] && [ "$noisy" = "0" ]; then
        pass "D02-non-protected-path-silent-approve"
    else
        fail "D02-non-protected-path-silent-approve" "verdict=$v stderr=[$HOOK_ERR] (marker check must run only after a protected hit)"
    fi
}

test_D01
test_D02

echo ""
echo "=== E: fail-open on malformed stdin must not regress ==="

test_E01() {
    local wfdir; wfdir="$(fresh_workflow_dir e01)"
    write_marker_file "$wfdir" "$SID"
    run_hook 'not json at all {{{' "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then fail "E01-malformed-json-approves" "expected rc=0, got rc=$HOOK_RC err=$HOOK_ERR"; return; fi
    assert_eq "E01-malformed-json-approves" "approve" "$(verdict)"
}

test_E01

echo ""
echo "=== F: attack fixture — bypass verdict is a real approve, not an absent deny ==="
#
# Mirrors tests/feature-1611 T1-A, inverted: a real sentinel archive file is created
# and the write is gated on the guard's verdict. With the marker present the write
# MUST go through — if the assertion were vacuous (hook silent / crashed / emitting
# something that merely lacks "deny"), the sentinel would stay byte-identical and
# F02 fails. The exact approve JSON contract is asserted separately in F03.

ATTACK_DIR="$TMPDIR_BASE/attack"
mkdir -p "$ATTACK_DIR/docs/history"
SENTINEL="$ATTACK_DIR/docs/history/2026.md"
printf '### Sentinel entry (2026-01-01, abc1234)\nBackground: untouched.\n' > "$SENTINEL"
SENTINEL_HASH_BEFORE="$(md5sum "$SENTINEL" | cut -d' ' -f1)"

test_F() {
    local wfdir; wfdir="$(fresh_workflow_dir f)"
    write_marker_file "$wfdir" "$SID"
    run_hook "$(payload_file "$SID" Edit "$SENTINEL")" "$wfdir"
    local v; v="$(verdict)"
    # Gated write: performed only when the guard did NOT block.
    [ "$v" = "block" ] || printf 'appended under WORKFLOW_OFF\n' >> "$SENTINEL"
    assert_eq "F01-marker-real-path-approves" "approve" "$v"
    local after; after="$(md5sum "$SENTINEL" | cut -d' ' -f1)"
    if [ "$after" != "$SENTINEL_HASH_BEFORE" ]; then
        pass "F02-gated-write-actually-happened (non-vacuous fixture)"
    else
        fail "F02-gated-write-actually-happened" "sentinel unchanged — the guard blocked, so the bypass did not apply"
    fi
    # Exact JSON contract, not merely "does not say deny".
    if [ "$HOOK_OUT" = '{"decision":"approve"}' ]; then
        pass "F03-exact-approve-json-contract"
    else
        fail "F03-exact-approve-json-contract" "stdout=[$HOOK_OUT] want={\"decision\":\"approve\"}"
    fi
}

test_F

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
