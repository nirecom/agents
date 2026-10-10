#!/usr/bin/env bash
# tests/bin/feature-2434-worker-control-paths.sh
# Tests: bin/worker-dispatch.js, bin/worker-dispatch/payload.js, bin/worker-dispatch/fsguard.js, bin/worker-dispatch/workers/issue-close-finalize.js, hooks/stop-final-report-guard.js
# Tags: worker-dispatch, control-dir, fsguard, stop-guard, TL2, scope:issue-specific
#
# Issue #2434 — control files move to WORKFLOW_STATE_DIR/<sid>.control/.
# Tests payload residency, fsguard scopes, stop-guard gate path, double-dispatch.
#
# TL3 gap: real gh calls (run-initial/run-finalize-terminal), CLI end-to-end
# (feature-2434-worker-payload-cli.sh), real session-close gate yield path.
# Mitigation: TL3 test hooks checked at WORKFLOW_USER_VERIFIED preflight.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# harness.sh assert_eq is 2-arg (actual, expected); override with 3-arg (name, expected, actual).
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

DISPATCH_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch.js"
PRELOAD="$SCRIPT_CHECKOUT_ROOT/tests/feature-1643-worker-dispatch-lib/spawn-stub.js"
FSGUARD_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch/fsguard.js"
HOOK_JS="$SCRIPT_CHECKOUT_ROOT/hooks/stop-final-report-guard.js"

TMPD="$(make_tmp)"
trap 'rm -rf "$TMPD"' EXIT

harness_isolate "$TMPD"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPD/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"

P_DIR="$WORKFLOW_PLANS_DIR"
W_DIR="$WORKFLOW_STATE_DIR"

# Shared git fixture
MAIN_RAW="$TMPD/mainrepo"
mkdir -p "$MAIN_RAW"
harness_git_init "$MAIN_RAW"
git -C "$MAIN_RAW" config user.email "test@example.com"
git -C "$MAIN_RAW" config user.name "Test"
printf 'init\n' > "$MAIN_RAW/README.md"
git -C "$MAIN_RAW" add "$MAIN_RAW/README.md" >/dev/null 2>&1 || true
git -C "$MAIN_RAW" commit -q --no-verify -m initial >/dev/null 2>&1 || true
MAIN="$(np "$MAIN_RAW")"
CANNED="$TMPD/canned.json"
CALLLOG="$TMPD/calls.jsonl"
INIT_CANNED='[{"stdout":"STATUS=init_done\nOWNER_REPO=o/r\n"}]'

dispatch() {
    local payload_path="$1" canned_json="$2"
    printf '%s' "$canned_json" > "$CANNED"
    printf '' > "$CALLLOG"
    DOUT=""
    DRC=0
    DOUT="$(env "WORKFLOW_PLANS_DIR=$(np "$P_DIR")" \
        "WD_SPAWN_MODULE=$(np "$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch/spawn.js")" \
        "WD_CANNED=$(np "$CANNED")" \
        "WD_CALL_LOG=$(np "$CALLLOG")" \
        node -r "$(np "$PRELOAD")" "$(np "$DISPATCH_JS")" \
        issue-close-finalize "$MAIN" "$payload_path" 2>/dev/null)" || DRC=$?
}

# ==========================================================================
case_begin "control-dir-dispatch" "bin/worker-dispatch.js"
# Payload in the control dir accepted after fix.
# Before fix: loadPayload checks PLANS residency → rejects → non-0 → FAIL.
# After  fix: control-dir payload accepted → exit 0 → PASS.
SID_CD="test2434cd"
CTRL_CD="$W_DIR/$SID_CD.control"
mkdir -p "$CTRL_CD"
CD_PAYLOAD="$CTRL_CD/worker-issue-close-finalize-1.json"
printf '%s' "{\"phase\":\"initial\",\"issue_number\":1,\"root_issue_number\":1,\"owner_repo\":\"o/r\",\"target_main_root\":\"$MAIN\",\"session_id\":\"$SID_CD\",\"artifact_dir\":\"$(np "$P_DIR")\"}" > "$CD_PAYLOAD"
if [ -f "$DISPATCH_JS" ] && [ -f "$PRELOAD" ]; then
    dispatch "$(np "$CD_PAYLOAD")" "$INIT_CANNED"
    assert_eq "control-dir-dispatch/exit-0" "0" "$DRC"
    DISPATCHED_F="$CTRL_CD/worker-issue-close-finalize-1.dispatched"
    if [ -f "$DISPATCHED_F" ]; then pass "control-dir-dispatch/dispatched-marker-written"
    else fail "control-dir-dispatch/dispatched-marker-written" "not implemented: no .dispatched in control dir"; fi
else
    fail "control-dir-dispatch/exit-0" "dispatcher or spawn-stub absent"
    fail "control-dir-dispatch/dispatched-marker-written" "dispatcher or spawn-stub absent"
fi
case_end

# ==========================================================================
case_begin "legacy-plans-dispatch" "bin/worker-dispatch.js"
# PLANS-dir payload still accepted (shim must not break existing behaviour).
# Passes today and must keep passing after the fix.
SID_LP="test2434lp"
LP_PAYLOAD="$P_DIR/$SID_LP-worker-issue-close-finalize-1.json"
printf '%s' "{\"phase\":\"initial\",\"issue_number\":1,\"root_issue_number\":1,\"owner_repo\":\"o/r\",\"target_main_root\":\"$MAIN\",\"session_id\":\"$SID_LP\",\"artifact_dir\":\"$(np "$P_DIR")\"}" > "$LP_PAYLOAD"
if [ -f "$DISPATCH_JS" ] && [ -f "$PRELOAD" ]; then
    dispatch "$(np "$LP_PAYLOAD")" "$INIT_CANNED"
    assert_eq "legacy-plans-dispatch/exit-0" "0" "$DRC"
else
    fail "legacy-plans-dispatch/exit-0" "dispatcher or spawn-stub absent"
fi
case_end

# ==========================================================================
case_begin "fsguard-rejects-control-in-plansdir" "bin/worker-dispatch/fsguard.js"
# After fix: writeScopes = ["control-dir"] — assertWritable to PLANS_DIR throws.
# Before fix: writeScopes = ["plans-dir"] — PLANS path allowed → "allowed" → FAIL.
if [ -f "$FSGUARD_JS" ]; then
    FG_RESULT="$(node -e "
const fg = require('$(np "$FSGUARD_JS")');
const p = '$(np "$P_DIR")/worker-issue-close-finalize-1.json';
const ctx = { plansDir: '$(np "$P_DIR")', controlDir: '$(np "$W_DIR/test2434fg.control")' };
try { fg.assertWritable('issue-close-finalize', p, ctx); process.stdout.write('allowed'); }
catch(e) { process.stdout.write('blocked'); }
" 2>/dev/null)"
    assert_eq "fsguard-control-in-plansdir/blocked" "blocked" "$FG_RESULT"
else
    fail "fsguard-control-in-plansdir/blocked" "not implemented: fsguard.js absent"
fi
case_end

# ==========================================================================
case_begin "dispatched-marker-blocks-repeat" "bin/worker-dispatch/payload.js"
# Second dispatch of same payload with .dispatched marker → non-0 exit.
# Before fix: no .dispatched logic in control dir → may succeed → FAIL.
# After  fix: .dispatched marker blocks re-dispatch → PASS.
SID_DBR="test2434dbr"
CTRL_DBR="$W_DIR/$SID_DBR.control"
mkdir -p "$CTRL_DBR"
DBR_PAYLOAD="$CTRL_DBR/worker-issue-close-finalize-1.json"
printf '%s' "{\"phase\":\"initial\",\"issue_number\":1,\"root_issue_number\":1,\"owner_repo\":\"o/r\",\"target_main_root\":\"$MAIN\",\"session_id\":\"$SID_DBR\",\"artifact_dir\":\"$(np "$P_DIR")\"}" > "$DBR_PAYLOAD"
touch "$CTRL_DBR/worker-issue-close-finalize-1.dispatched"
if [ -f "$DISPATCH_JS" ] && [ -f "$PRELOAD" ]; then
    dispatch "$(np "$DBR_PAYLOAD")" "$INIT_CANNED"
    if [ "$DRC" -ne 0 ]; then pass "dispatched-marker-blocks-repeat/exit-nonzero"
    else fail "dispatched-marker-blocks-repeat/exit-nonzero" "expected non-0 for double-dispatch; not implemented"; fi
else
    fail "dispatched-marker-blocks-repeat/exit-nonzero" "dispatcher or spawn-stub absent"
fi
case_end

# ==========================================================================
case_begin "stop-guard-reads-control-gate" "hooks/stop-final-report-guard.js"
# After fix: gate at <sid>.control/session-close-gate.json with gate_action=yield
# causes the hook to exit 0.
# Before fix: hook reads from PLANS_DIR → gate absent → fake next-step triggers
# block path → hook exits 2 → assertion FAILS.
SID_SG="test2434sg"
CTRL_SG="$W_DIR/$SID_SG.control"
mkdir -p "$CTRL_SG"
printf '%s' '{"gate_action":"yield","reason":"test"}' > "$CTRL_SG/session-close-gate.json"

# Fake next-step: returns block condition (so pre-fix behaviour is detectable).
# The hook finds next-step from its own location, so it runs from a copied hooks tree.
FAKE_SCRIPT_CHECKOUT_ROOT="$TMPD/fake-checkout"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"
script_checkout_fixture_copy "$FAKE_SCRIPT_CHECKOUT_ROOT" hooks
mkdir -p "$FAKE_SCRIPT_CHECKOUT_ROOT/bin/workflow"
printf '%s\n' \
    '#!/usr/bin/env node' \
    "process.stdout.write(\"ACTION=invoke\\nNEXT_SKILL=session-close\\nREASON='pre_final_report_gate'\\n\");" \
    'process.exit(0);' > "$FAKE_SCRIPT_CHECKOUT_ROOT/bin/workflow/next-step"

if [ -f "$HOOK_JS" ]; then
    SG_OUT="$(printf '{"session_id":"%s"}' "$SID_SG" | node "$(np "$FAKE_SCRIPT_CHECKOUT_ROOT/hooks/stop-final-report-guard.js")" 2>/dev/null)" ; SG_RC=$?
    assert_eq "stop-guard/gate-in-control-yields-exit-0" "0" "$SG_RC"
else
    fail "stop-guard/gate-in-control-yields-exit-0" "not implemented: stop-final-report-guard absent"
fi
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
