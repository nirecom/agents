#!/usr/bin/env bash
# tests/hooks/feature-2434-placement-guard.sh
# Tests: hooks/block-clearance-token-write.js, hooks/block-clearance-token-write/placement-guard.js, hooks/block-clearance-token-write/dispatch.js
# Tags: scope:issue-specific, feature-2434, placement-guard, control-dir, plans-unregistered, TL2, TL1, hook-registration, pwsh-not-required
# TL3 gap (what this test does NOT catch):
# - The hook firing on a real host with full claude -p session (covered by TL3-hook-clearance-token-write.sh)
# - placement-guard entrypoint wiring verified by TL3 cases appended to that file
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"

RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
AGENTS_N="$(np "$AGENTS_DIR")"

TMP="$(make_tmp)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
harness_isolate "$TMP"
TRANS_TMP="$(make_tmp)"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TRANS_TMP"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

HOOK="$AGENTS_DIR/hooks/block-clearance-token-write.js"
GUARD_JS="$AGENTS_DIR/hooks/block-clearance-token-write/placement-guard.js"
DISPATCH_JS="$AGENTS_DIR/hooks/block-clearance-token-write/dispatch.js"

HOOK_PRESENT=no;  [ -f "$HOOK" ]     && HOOK_PRESENT=yes
GUARD_PRESENT=no; [ -f "$GUARD_JS" ] && GUARD_PRESENT=yes

WFN="$(np "$WORKFLOW_STATE_DIR")"
PLDN="$(np "$WORKFLOW_PLANS_DIR")"
SID="aa000000-0000-4000-8000-000000001234"
DATE_SID="20260601-120000"
DERIVED_SID="cc000000-0000-4000-8000-000000003333-b1"

# Create sid.json so the session is "known"
printf '{}' > "$WORKFLOW_STATE_DIR/$SID.json"
mkdir -p "$WORKFLOW_STATE_DIR/$SID.control"

# ── local verdict helpers ──────────────────────────────────────────
# The hook always sees the one plans root the targets below are built from
# ($PLDN), so a PLANS_DIR verdict is a verdict about the configured plans dir.
local_run_hook() {
    local tn="$1" input="$2" out rc
    [ "$HOOK_PRESENT" = "yes" ] || { printf 'absent|'; return; }
    out=$(WORKFLOW_STATE_DIR="$tn" WORKFLOW_PLANS_DIR="$PLDN" AGENTS_CONFIG_DIR="$AGENTS_N" \
        "$RWT" 12 node "$HOOK" <<< "$input" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr -d '\r\n')"
}
local_classify() {
    local raw="$1" rc out
    rc="${raw%%|*}"; out="${raw#*|}"
    case "$rc" in
        absent) printf 'hook-absent'; return ;;
        124)    printf 'timeout'; return ;;
        0)      ;;
        *)      printf 'crash:%s' "$rc"; return ;;
    esac
    [ -z "$out" ] && { printf 'empty'; return; }
    case "$out" in
        *'"decision":"block"'*)   printf 'block'; return ;;
        *'"decision":"approve"'*) printf 'approve'; return ;;
        *'"permissionDecision":"allow"'*) printf 'approve'; return ;;
        *'"continue":true'*)      printf 'approve'; return ;;
    esac
    printf 'unrecognized'
}
mk_bash_in() {
    "$RWT" 8 node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:process.argv[1],tool_input:{command:process.argv[2]}}))" "$SID" "$1" 2>/dev/null
}
mk_file_in() {
    "$RWT" 8 node -e "process.stdout.write(JSON.stringify({tool_name:process.argv[1],session_id:process.argv[2],tool_input:{file_path:process.argv[3]}}))" "$1" "$SID" "$2" 2>/dev/null
}
expect_block() {
    local label="$1" verdict="$2"
    case "$verdict" in
        block) pass "$label -> block" ;;
        hook-absent) skip "$label (hook absent)" ;;
        *)
            if [ "$GUARD_PRESENT" = "no" ]; then
                fail "$label want=block got=$verdict  RED-EXPECTED: placement-guard.js not yet created"
            else
                fail "$label want=block got=$verdict"
            fi
            ;;
    esac
}
expect_approve() {
    local label="$1" verdict="$2"
    case "$verdict" in
        approve) pass "$label -> approve" ;;
        hook-absent) skip "$label (hook absent)" ;;
        *) fail "$label want=approve got=$verdict" ;;
    esac
}
expect_absent() {
    if [ -e "$2" ]; then fail "$1" "unexpected file: $2"; else pass "$1"; fi
}
# sum_of <file> — content fingerprint ("missing" when absent), for byte-identity checks.
sum_of() {
    if [ -f "$1" ]; then cksum < "$1" | tr -d ' \t\r\n'; else printf 'missing'; fi
}
expect_unchanged() {
    local label="$1" file="$2" before="$3" now
    now="$(sum_of "$file")"
    if [ "$now" = "$before" ]; then pass "$label"; else fail "$label" "before=$before now=$now"; fi
}

# Fake HOME whose ~/.claude/projects/workflow is the workflow dir, so the $HOME /
# ~ / ${WORKFLOW_STATE_DIR} spellings all name the same known session.
fake_home_enter() {
    FAKE_HOME="$(make_tmp)"
    ORIG_HOME="$HOME"
    export HOME="$FAKE_HOME"
    export WORKFLOW_STATE_DIR="$FAKE_HOME/.claude/projects/workflow"
    mkdir -p "$WORKFLOW_STATE_DIR/$SID.control"
    printf '{"sid":"%s"}' "$SID" > "$WORKFLOW_STATE_DIR/$SID.json"
    WFNA="$(np "$WORKFLOW_STATE_DIR")"
}
fake_home_leave() {
    export HOME="$ORIG_HOME"
    export WORKFLOW_STATE_DIR="$TMP/workflow-state"
    printf '{}' > "$WORKFLOW_STATE_DIR/$SID.json"
    rm -rf "$FAKE_HOME" 2>/dev/null || true
}

# Hook-verdict and side-effect cases live in the sibling folder (file-size split);
# the dispatch.js static cases stay inline, in the original order between them.
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-2434-placement-guard"
# shellcheck source=./feature-2434-placement-guard/verdict-cases.sh
. "$SCRIPT_DIR/verdict-cases.sh"

# ════════════════════════════════════════════════════════════════════
case_begin "block-message-kinds" "hooks/block-clearance-token-write/dispatch.js"

# blockMessageFor must support 'control-dir', 'plans-unregistered', 'alias-unresolved'
DISP_PROBE="try{const d=require(process.argv[1]);const fn=d.blockMessageFor;if(typeof fn!=='function'){process.stdout.write('no-fn');}else{const c=fn('control-dir');const p=fn('plans-unregistered');const a=fn('alias-unresolved');process.stdout.write(c&&p&&a&&c!==p?'ok':'mismatch');}}catch(e){process.stdout.write('ERR:'+e.message.slice(0,60));}"
DISP_GOT="$("$RWT" 8 node -e "$DISP_PROBE" "$DISPATCH_JS" 2>/dev/null)"

case "$DISP_GOT" in
    ok) pass "dispatch blockMessageFor supports new kinds" ;;
    no-fn|mismatch) fail "dispatch blockMessageFor new kinds missing  RED-EXPECTED: not yet implemented" ;;
    ERR:*) fail "dispatch.js load error: $DISP_GOT  RED-EXPECTED: not yet wired" ;;
    *) fail "dispatch blockMessageFor unexpected: $DISP_GOT" ;;
esac

# Messages must mention state-dirs doc
STATE_DIRS_PROBE="try{const d=require(process.argv[1]);const fn=d.blockMessageFor;if(typeof fn==='function'){const c=fn('control-dir');process.stdout.write(/state-dirs/.test(c)?'yes':'no');}else{process.stdout.write('no-fn');}}catch(e){process.stdout.write('ERR');}"
SDREF_GOT="$("$RWT" 8 node -e "$STATE_DIRS_PROBE" "$DISPATCH_JS" 2>/dev/null)"
case "$SDREF_GOT" in
    yes) pass "control-dir message references state-dirs" ;;
    no|no-fn) fail "control-dir message missing state-dirs ref  RED-EXPECTED" ;;
    *) fail "state-dirs probe unexpected: $SDREF_GOT" ;;
esac

case_end

# ════════════════════════════════════════════════════════════════════
case_begin "dispatch-static" "hooks/block-clearance-token-write/dispatch.js"

# dispatch.js must require/call placement-guard (static wiring check)
WIRE_PROBE="try{const fs=require('fs');const src=fs.readFileSync(process.argv[1],'utf8');const i=/placement-guard/.test(src);const c=/classifyPlacement/.test(src);process.stdout.write(i&&c?'wired':!i?'no-import':'no-call');}catch(e){process.stdout.write('ERR:'+e.message.slice(0,60));}"
WIRE_GOT="$("$RWT" 8 node -e "$WIRE_PROBE" "$DISPATCH_JS" 2>/dev/null)"

case "$WIRE_GOT" in
    wired) pass "dispatch.js wires placement-guard" ;;
    no-import) fail "dispatch.js does not import placement-guard  RED-EXPECTED: wiring not yet done" ;;
    no-call) fail "dispatch.js does not call classifyPlacement  RED-EXPECTED: wiring not yet done" ;;
    ERR:*) fail "dispatch-static read error: $WIRE_GOT" ;;
    *) fail "dispatch-static unexpected: $WIRE_GOT" ;;
esac

case_end

# shellcheck source=./feature-2434-placement-guard/side-effects.sh
. "$SCRIPT_DIR/side-effects.sh"

# Strict classifier cases (TL1, called directly — no hook process).
# shellcheck source=./feature-2434-placement-guard/strict-cases.sh
. "$SCRIPT_DIR/strict-cases.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
