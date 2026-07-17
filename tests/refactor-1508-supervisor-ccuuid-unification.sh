#!/bin/bash
# tests/refactor-1508-supervisor-ccuuid-unification.sh
# Tests: bin/supervisor-report, hooks/supervisor-guard.js, hooks/stop-l2-findings-display.js, hooks/lib/supervisor-state-writer.js
# Tags: supervisor, em-supervisor, session-id, cc-uuid, refactor, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Real Stop hook invocation with actual Claude Code session
# - CLAUDE_CODE_SESSION_ID env var propagation from real hook environment
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
#
# NOTE: Cases N1, N2, R1 test the FUTURE behavior after #1508 is implemented.
# They SKIP until implementation lands (probe: absence of rawSidSource="wsid").
# E1 and N3 test behavior preserved across the refactor.
# W1 tests the current (pre-#1508) wsid-primary auto-resolve happy path.
# V1 and V2 test argument validation (preserved across the refactor).
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
    _TMPCONV() { cygpath -m "$1"; }
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
    _TMPCONV() { printf '%s' "$1"; }
fi

CLI="$AGENTS_DIR/bin/supervisor-report"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}


require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

# Probe: returns 0 when #1508 CC-UUID-primary refactor has been applied.
# Before #1508: rawSidSource="wsid" exists in auto-resolve block (wsid-preferred).
# After  #1508: that assignment removed; CC UUID is sole auto-resolve path.
ccuuid_primary_implemented() {
    [ -f "$CLI" ] || return 1
    grep -qE 'rawSidSource\s*=\s*"wsid"' "$CLI" 2>/dev/null && return 1
    return 0
}

require_ccuuid_primary() {
    local label="$1"
    require_source "$CLI" "$label" || return 1
    if ! ccuuid_primary_implemented; then
        skip "$label (CC UUID primary refactor #1508 not yet implemented)"; return 1
    fi
    return 0
}

# SKIP after #1508 removes wsid-primary path; guard for pre-refactor-only cases.
require_not_ccuuid_primary() {
    local label="$1"
    require_source "$CLI" "$label" || return 1
    if ccuuid_primary_implemented; then
        skip "$label (wsid-primary path removed in #1508 — pre-refactor behavior)"; return 1
    fi
    return 0
}

count_findings() {
    local tmp="$1" sid="$2"
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
if (!st || !st.layer1 || !Array.isArray(st.layer1.findings)) { process.stdout.write('0'); process.exit(0); }
process.stdout.write(String(st.layer1.findings.length));
" 2>/dev/null
    )
}


state_file_count() {
    local tmp="$1"
    ls "$tmp"/*-supervisor-state.json 2>/dev/null | wc -l | tr -d ' '
}

state_file_exists() {
    local tmp="$1" sid="$2"
    [ -f "$tmp/${sid}-supervisor-state.json" ] && echo "1" || echo "0"
}

# N1: CLAUDE_CODE_SESSION_ID=<uuid> set -> supervisor-report writes to
#     <uuid>-supervisor-state.json. After #1508: CC UUID is primary auto-resolve.
run_n1() {
    local label="N1: CLAUDE_CODE_SESSION_ID set -> state file keyed on CC UUID"
    require_ccuuid_primary "$label" || return
    local tmp uuid n_uuid total
    tmp="$(mktemp -d)"
    uuid="aaaabbbb-cccc-dddd-eeee-ffffffffffff"
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        export CLAUDE_CODE_SESSION_ID="$uuid"
        unset WORKFLOW_SESSION_ID 2>/dev/null || true
        unset CLAUDE_ENV_FILE 2>/dev/null || true
        cd "$tmp" && run_with_timeout 5 node "$CLI" \
            --categories code \
            --severity warning \
            --detail "n1 finding" \
            --reporter test >/dev/null 2>&1
    )
    n_uuid=$(count_findings "$tmp" "$uuid")
    total=$(state_file_count "$tmp")
    rm -rf "$tmp"
    if [ "$n_uuid" = "1" ] && [ "$total" = "1" ]; then
        pass "$label"
    else
        fail "$label (n_uuid=$n_uuid, total=$total)"
    fi
}

# N2: CC UUID auto-resolve -> NO wsid mirror-write (auto-mirror removed in #1508).
# WORKTREE_NOTES.md present to simulate wsid availability, but after #1508 no mirror fires.
run_n2() {
    local label="N2: CC UUID auto-resolve -> no wsid mirror-write"
    require_ccuuid_primary "$label" || return
    local tmp uuid wsid_like total n_uuid exists_wsid
    tmp="$(mktemp -d)"
    uuid="11112222-3333-4444-5555-666677778888"
    wsid_like="20260718-120000-n2wsid"
    printf "Session-ID: %s\n" "$wsid_like" > "$tmp/WORKTREE_NOTES.md"
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        export CLAUDE_CODE_SESSION_ID="$uuid"
        unset CLAUDE_ENV_FILE 2>/dev/null || true
        cd "$tmp" && run_with_timeout 5 node "$CLI" \
            --categories workflow \
            --severity notice \
            --detail "n2 no mirror" \
            --reporter test >/dev/null 2>&1
    )
    n_uuid=$(count_findings "$tmp" "$uuid")
    exists_wsid=$(state_file_exists "$tmp" "$wsid_like")
    total=$(state_file_count "$tmp")
    rm -rf "$tmp"
    if [ "$n_uuid" = "1" ] && [ "$exists_wsid" = "0" ] && [ "$total" = "1" ]; then
        pass "$label"
    else
        fail "$label (n_uuid=$n_uuid, exists_wsid=$exists_wsid, total=$total)"
    fi
}

# N3: Explicit --session-id writes to that store (regression guard, unchanged by #1508).
run_n3() {
    local label="N3: explicit --session-id still writes to that store"
    require_source "$CLI" "$label" || return
    local tmp sid n
    tmp="$(mktemp -d)"
    sid="n3-explicit-sid"
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
        unset WORKFLOW_SESSION_ID 2>/dev/null || true
        unset CLAUDE_ENV_FILE 2>/dev/null || true
        run_with_timeout 5 node "$CLI" \
            --session-id "$sid" \
            --categories code \
            --severity warning \
            --detail "n3 explicit sid" \
            --reporter test >/dev/null 2>&1
    )
    n=$(count_findings "$tmp" "$sid")
    rm -rf "$tmp"
    if [ "$n" = "1" ]; then
        pass "$label"
    else
        fail "$label (n=$n)"
    fi
}

# R1: When CLAUDE_CODE_SESSION_ID is set, auto-resolve picks CC UUID, NOT wsid.
# WORKTREE_NOTES.md supplies a wsid-form Session-ID. After #1508: wsid auto-resolve removed.
run_r1() {
    local label="R1: CC UUID wins over wsid-form ID in auto-resolve"
    require_ccuuid_primary "$label" || return
    local tmp uuid wsid_like n_uuid exists_wsid total
    tmp="$(mktemp -d)"
    uuid="99998888-7777-6666-5555-444433332222"
    wsid_like="20260718-120000-r1wsid"
    printf "Session-ID: %s\n" "$wsid_like" > "$tmp/WORKTREE_NOTES.md"
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        export CLAUDE_CODE_SESSION_ID="$uuid"
        unset CLAUDE_ENV_FILE 2>/dev/null || true
        cd "$tmp" && run_with_timeout 5 node "$CLI" \
            --categories intent \
            --severity notice \
            --detail "r1 cc uuid primary" \
            --reporter test >/dev/null 2>&1
    )
    n_uuid=$(count_findings "$tmp" "$uuid")
    exists_wsid=$(state_file_exists "$tmp" "$wsid_like")
    total=$(state_file_count "$tmp")
    rm -rf "$tmp"
    if [ "$n_uuid" = "1" ] && [ "$exists_wsid" = "0" ] && [ "$total" = "1" ]; then
        pass "$label"
    else
        fail "$label (n_uuid=$n_uuid, exists_wsid=$exists_wsid, total=$total)"
    fi
}

# W1: Current (pre-#1508) wsid-primary auto-resolve happy path.
# WORKTREE_NOTES.md Session-ID in CWD is picked up as priority-1 wsid.
# SKIP after #1508 removes wsid auto-resolve.
run_w1() {
    local label="W1: wsid-primary auto-resolve via WORKTREE_NOTES.md (pre-#1508 behavior)"
    require_not_ccuuid_primary "$label" || return
    local tmp wsid n
    tmp="$(mktemp -d)"
    wsid="20260718-120000-w1test"
    printf "Session-ID: %s\n" "$wsid" > "$tmp/WORKTREE_NOTES.md"
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
        unset CLAUDE_SESSION_ID 2>/dev/null || true
        unset CLAUDE_ENV_FILE 2>/dev/null || true
        cd "$tmp" && run_with_timeout 5 node "$CLI" \
            --categories code \
            --severity warning \
            --detail "w1 wsid auto-resolve" \
            --reporter test >/dev/null 2>&1
    )
    n=$(count_findings "$tmp" "$wsid")
    rm -rf "$tmp"
    if [ "$n" = "1" ]; then
        pass "$label"
    else
        fail "$label (n=$n)"
    fi
}

# V1: Missing required argument → non-zero exit with usage message.
run_v1() {
    local label="V1: missing required arg (--reporter absent) -> non-zero exit + usage"
    require_source "$CLI" "$label" || return
    local tmp combined exit_code
    tmp="$(mktemp -d)"
    combined=$(
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        run_with_timeout 5 node "$CLI" \
            --session-id "explicit-sid-v1" \
            --categories code \
            --severity warning \
            --detail "v1 test" \
            2>&1
        printf "\nEXIT:%s" "$?"
    )
    rm -rf "$tmp"
    exit_code=$(printf '%s' "$combined" | grep "EXIT:" | sed 's/.*EXIT://')
    if [ "$exit_code" != "0" ] && printf '%s' "$combined" | grep -qiE 'required|Usage'; then
        pass "$label"
    else
        fail "$label (exit=$exit_code, output=$combined)"
    fi
}

# V2: Invalid --session-id charset (SESSION_ID_RE: /^[A-Za-z0-9_-]+$/) → non-zero exit.
run_v2() {
    local label="V2: invalid --session-id charset -> non-zero exit"
    require_source "$CLI" "$label" || return
    local tmp combined exit_code
    tmp="$(mktemp -d)"
    combined=$(
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        run_with_timeout 5 node "$CLI" \
            --session-id "bad/sid/with/slashes" \
            --categories code \
            --severity warning \
            --detail "v2 test" \
            --reporter test \
            2>&1
        printf "\nEXIT:%s" "$?"
    )
    rm -rf "$tmp"
    exit_code=$(printf '%s' "$combined" | grep "EXIT:" | sed 's/.*EXIT://')
    if [ "$exit_code" != "0" ]; then
        pass "$label"
    else
        fail "$label (exit=$exit_code, should be non-zero for invalid sid)"
    fi
}

# E1: No session context at all -> non-zero exit with error (unchanged by #1508).
run_e1() {
    local label="E1: no session context -> non-zero exit with error message"
    require_source "$CLI" "$label" || return
    local tmp combined exit_code
    tmp="$(mktemp -d)"
    combined=$(
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
        unset CLAUDE_SESSION_ID 2>/dev/null || true
        unset CLAUDE_ENV_FILE 2>/dev/null || true
        unset WORKFLOW_SESSION_ID 2>/dev/null || true
        cd "$tmp" && run_with_timeout 5 node "$CLI" \
            --categories code \
            --severity warning \
            --detail "e1 no session" \
            --reporter test 2>&1
        printf "\nEXIT:%s" "$?"
    )
    rm -rf "$tmp"
    exit_code=$(printf '%s' "$combined" | grep "EXIT:" | sed 's/.*EXIT://')
    if [ "$exit_code" != "0" ] && printf '%s' "$combined" | grep -qiE 'auto-resolve|session-id required'; then
        pass "$label"
    else
        fail "$label (exit=$exit_code, output=$combined)"
    fi
}

echo "=== refactor-1508-supervisor-ccuuid-unification.sh ==="
echo ""
echo "N1/N2/R1: future CC UUID primary (#1508) -- SKIP until implemented."
echo "W1: current wsid-primary behavior -- SKIP after #1508 removes wsid path."
echo "E1/N3/V1/V2: preserved behavior (passes before and after #1508)."
echo ""

run_n3
run_e1
run_w1
run_v1
run_v2
run_n1
run_n2
run_r1

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
