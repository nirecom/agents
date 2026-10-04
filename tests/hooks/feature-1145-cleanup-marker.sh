#!/usr/bin/env bash
# tests/hooks/feature-1145-cleanup-marker.sh
# Tests: hooks/lib/worktree-cleanup-marker.js, hooks/lib/worktree-end-env-anchor.js
# Tags: scope:issue-specific, pwsh-not-required, worktree-end, cleanup-marker, control-dir
# L1 unit tests for the worktree-cleanup-marker.js CLI (create/delete of <workflow-dir>/<sid>.control/wt-cleanup-active).
# Each case dual-pins WORKFLOW_STATE_DIR (<tmp>/wf) and WORKFLOW_PLANS_DIR (<tmp>/plans) to its own fixture.
#
# L3 gap (what this test does NOT catch):
# - The marker CLI being invoked at the correct WE steps inside a live claude -p session.
# - Real CLAUDE_SESSION_ID propagation from the worktree-end skill environment.
# Closest-to-action mitigation: hook-registration category checked at WORKFLOW_USER_VERIFIED preflight.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# harness.sh also unsets CLAUDE_SESSION_ID / CLAUDE_CODE_SESSION_ID / CLAUDE_ENV_FILE;
# cases that need an env sid set it explicitly.
source "$AGENTS_DIR/tests/lib/harness.sh"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

MARKER_NODE="$_AGENTS_DIR_NODE/hooks/lib/worktree-cleanup-marker.js"
MARKER="$AGENTS_DIR/hooks/lib/worktree-cleanup-marker.js"
ANCHOR_NODE="$_AGENTS_DIR_NODE/hooks/lib/worktree-end-env-anchor.js"
ANCHOR="$AGENTS_DIR/hooks/lib/worktree-end-env-anchor.js"

# make_fixture — a temp dir holding the pinned workflow dir (wf) and plans dir (plans).
make_fixture() {
    local d
    d="$(make_tmp)"
    mkdir -p "$d/wf" "$d/plans"
    printf '%s' "$d"
}

tmp_node_for() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# marker_at <tmp> <sid> — the control-dir marker path for <sid> inside the fixture.
marker_at() { printf '%s/wf/%s.control/wt-cleanup-active' "$1" "$2"; }
# legacy_at <tmp> <sid> — the pre-control-dir plans-dir path that must never be written.
legacy_at() { printf '%s/plans/%s-wt-cleanup-active' "$1" "$2"; }

# marker_cli <tmp> <args...> — run the marker CLI with both dirs pinned to the fixture.
marker_cli() {
    local tmp="$1"; shift
    WORKFLOW_STATE_DIR="$(tmp_node_for "$tmp/wf")" WORKFLOW_PLANS_DIR="$(tmp_node_for "$tmp/plans")" \
        run_with_timeout 10 node "$MARKER_NODE" "$@"
}

if [ ! -f "$MARKER" ]; then
    fail "T-marker: hooks/lib/worktree-cleanup-marker.js not present (RED-EXPECTED — not yet implemented)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# Helper: check if isWorktreeEndEnv returns true/false for given fixture + sid
call_anchor() {
    local tmp="$1" sid="$2"
    WORKFLOW_STATE_DIR="$(tmp_node_for "$tmp/wf")" WORKFLOW_PLANS_DIR="$(tmp_node_for "$tmp/plans")" \
        run_with_timeout 10 node -e "
const { isWorktreeEndEnv } = require('$ANCHOR_NODE');
console.log(isWorktreeEndEnv('$sid') ? 'true' : 'false');
" 2>/dev/null
}

# --- T-marker-1: create <sid> → marker file exists at <workflow-dir>/<sid>.control/wt-cleanup-active ---
run_t1() {
    local tmp sid rc
    tmp=$(make_fixture)
    sid="marker1-sid-$$"
    marker_cli "$tmp" create "$sid" >/dev/null 2>&1
    rc=$?
    local exists=0 legacy=0
    [ -f "$(marker_at "$tmp" "$sid")" ] && exists=1
    [ -e "$(legacy_at "$tmp" "$sid")" ] && legacy=1
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then fail "T-marker-1: create must exit 0, got rc=$rc"; return; fi
    if [ $exists -ne 1 ]; then fail "T-marker-1: marker file must exist after create"; return; fi
    if [ $legacy -ne 0 ]; then fail "T-marker-1: create must not write the legacy plans-dir marker"; return; fi
    pass "T-marker-1: create <sid> → <workflow-dir>/<sid>.control/wt-cleanup-active exists (no legacy plans-dir file)"
}

# --- T-marker-2: delete <sid> → marker file removed ---
run_t2() {
    local tmp sid rc exists
    tmp=$(make_fixture)
    sid="marker2-sid-$$"
    mkdir -p "$tmp/wf/${sid}.control"
    touch "$(marker_at "$tmp" "$sid")"
    marker_cli "$tmp" delete "$sid" >/dev/null 2>&1
    rc=$?
    exists=0
    [ -f "$(marker_at "$tmp" "$sid")" ] && exists=1
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then fail "T-marker-2: delete must exit 0, got rc=$rc"; return; fi
    if [ $exists -ne 0 ]; then fail "T-marker-2: marker file must be gone after delete"; return; fi
    pass "T-marker-2: delete <sid> → marker file removed"
}

# --- T-marker-3: delete when marker doesn't exist → exit 0 (fail-safe, no error) ---
run_t3() {
    local tmp sid rc
    tmp=$(make_fixture)
    sid="marker3-sid-$$"
    # no file created
    marker_cli "$tmp" delete "$sid" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then fail "T-marker-3: delete of absent marker must exit 0 (fail-safe), got rc=$rc"; return; fi
    pass "T-marker-3: delete when marker absent → exit 0 (fail-safe)"
}

# --- T-marker-4: create → isWorktreeEndEnv returns true; delete → returns false ---
run_t4() {
    local tmp sid out_after_create out_after_delete
    tmp=$(make_fixture)
    sid="marker4-sid-$$"

    marker_cli "$tmp" create "$sid" >/dev/null 2>&1
    out_after_create=$(call_anchor "$tmp" "$sid")

    marker_cli "$tmp" delete "$sid" >/dev/null 2>&1
    out_after_delete=$(call_anchor "$tmp" "$sid")

    rm -rf "$tmp"

    if [ "$out_after_create" != "true" ]; then
        fail "T-marker-4: after create, isWorktreeEndEnv must return true, got '$out_after_create'"; return; fi
    if [ "$out_after_delete" != "false" ]; then
        fail "T-marker-4: after delete, isWorktreeEndEnv must return false, got '$out_after_delete'"; return; fi
    pass "T-marker-4: create → isWorktreeEndEnv=true; delete → isWorktreeEndEnv=false (integration)"
}

# --- T-marker-5: empty SID → no file created, exit 0 (fail-safe) ---
run_t5() {
    local tmp rc file_count
    tmp=$(make_fixture)
    marker_cli "$tmp" create "" >/dev/null 2>&1
    rc=$?
    file_count=$(find "$tmp" \( -name "wt-cleanup-active" -o -name "*-wt-cleanup-active" \) | wc -l)
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then fail "T-marker-5: empty SID create must exit 0 (fail-safe), got rc=$rc"; return; fi
    if [ "$file_count" -ne 0 ]; then fail "T-marker-5: empty SID must not create any marker file, found $file_count"; return; fi
    pass "T-marker-5: empty SID → no marker created, exit 0 (fail-safe)"
}

# --- T-marker-6: unknown command ("bogus") → non-zero exit ---
run_t6() {
    local tmp sid rc
    tmp=$(make_fixture)
    sid="marker6-sid-$$"
    marker_cli "$tmp" bogus "$sid" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then fail "T-marker-6: unknown command must exit non-zero, got rc=0"; return; fi
    pass "T-marker-6: unknown command 'bogus' → non-zero exit (rc=$rc)"
}

# --- T-marker-7: SID via CLAUDE_SESSION_ID env (no positional arg) → creates file named by env SID ---
run_t7() {
    local tmp env_sid rc exists
    tmp=$(make_fixture)
    env_sid="marker7-env-sid-$$"
    (
        unset CLAUDE_CODE_SESSION_ID
        CLAUDE_SESSION_ID="$env_sid" marker_cli "$tmp" create >/dev/null 2>&1
    )
    rc=$?
    exists=0
    [ -f "$(marker_at "$tmp" "$env_sid")" ] && exists=1
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then fail "T-marker-7: create via CLAUDE_SESSION_ID must exit 0, got rc=$rc"; return; fi
    if [ $exists -ne 1 ]; then
        fail "T-marker-7: marker file must exist named by CLAUDE_SESSION_ID when no positional arg given"; return; fi
    pass "T-marker-7: SID from CLAUDE_SESSION_ID env (no positional arg) → marker created by env SID"
}

# --- T-marker-8 (#2270): SID via CLAUDE_CODE_SESSION_ID env only ---
# A non-native-LLM tool exports only CLAUDE_CODE_SESSION_ID. The marker is the
# worktree-cleanup safety latch, so failing to name it by that SID leaves the
# latch open for exactly the callers that cannot set CLAUDE_SESSION_ID.
# RED until the CLAUDE_CODE_SESSION_ID fallback lands in worktree-cleanup-marker.js.
run_t8() {
    local tmp env_sid rc exists
    tmp=$(make_fixture)
    env_sid="marker8-env-sid-$$"
    (
        unset CLAUDE_SESSION_ID
        CLAUDE_CODE_SESSION_ID="$env_sid" marker_cli "$tmp" create >/dev/null 2>&1
    )
    rc=$?
    exists=0
    [ -f "$(marker_at "$tmp" "$env_sid")" ] && exists=1
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then fail "T-marker-8: create via CLAUDE_CODE_SESSION_ID must exit 0, got rc=$rc"; return; fi
    if [ $exists -ne 1 ]; then
        fail "T-marker-8: marker file must exist named by CLAUDE_CODE_SESSION_ID when no positional arg given"; return; fi
    pass "T-marker-8: SID from CLAUDE_CODE_SESSION_ID env (no positional arg) → marker created by env SID"
}

# --- T-marker-9 (#2270): BOTH env vars set to different ids → which one names the
# marker. The SSOT resolver ranks CLAUDE_CODE_SESSION_ID (Priority 2) above
# CLAUDE_SESSION_ID (Priority 4); the marker must agree, or a session whose two
# variables disagree latches cleanup under an id nobody deletes.
run_t9() {
    local tmp cc_sid legacy_sid rc cc_exists legacy_exists
    tmp=$(make_fixture)
    cc_sid="marker9-cc-sid-$$"
    legacy_sid="marker9-legacy-sid-$$"
    (
        CLAUDE_SESSION_ID="$legacy_sid" \
        CLAUDE_CODE_SESSION_ID="$cc_sid" \
            marker_cli "$tmp" create >/dev/null 2>&1
    )
    rc=$?
    cc_exists=0; legacy_exists=0
    [ -f "$(marker_at "$tmp" "$cc_sid")" ] && cc_exists=1
    [ -f "$(marker_at "$tmp" "$legacy_sid")" ] && legacy_exists=1
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then fail "T-marker-9: create with both env vars must exit 0, got rc=$rc"; return; fi
    if [ $cc_exists -ne 1 ] || [ $legacy_exists -ne 0 ]; then
        fail "T-marker-9: CLAUDE_CODE_SESSION_ID must win (cc_exists=$cc_exists legacy_exists=$legacy_exists)"; return; fi
    pass "T-marker-9: both env vars set → CLAUDE_CODE_SESSION_ID names the marker"
}

case_begin "T-marker-1" "hooks/lib/worktree-cleanup-marker.js"
run_t1
case_end
case_begin "T-marker-2" "hooks/lib/worktree-cleanup-marker.js"
run_t2
case_end
case_begin "T-marker-3" "hooks/lib/worktree-cleanup-marker.js"
run_t3
case_end
case_begin "T-marker-4" "hooks/lib/worktree-end-env-anchor.js"
run_t4
case_end
case_begin "T-marker-5" "hooks/lib/worktree-cleanup-marker.js"
run_t5
case_end
case_begin "T-marker-6" "hooks/lib/worktree-cleanup-marker.js"
run_t6
case_end
case_begin "T-marker-7" "hooks/lib/worktree-cleanup-marker.js"
run_t7
case_end
case_begin "T-marker-8" "hooks/lib/worktree-cleanup-marker.js"
run_t8
case_end
case_begin "T-marker-9" "hooks/lib/worktree-cleanup-marker.js"
run_t9
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
