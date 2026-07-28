#!/usr/bin/env bash
# tests/feat-1608-emergency-sentinel.sh
# Tests: hooks/lib/sentinel-patterns.js, hooks/workflow-mark/enforce-override-handlers.js, hooks/supervisor-off-proposal-shim.js, hooks/supervisor-guard/detect.js, settings.json
# Tags: emergency-sentinel, off-gate, examination-bypass, sentinel-patterns, scope:issue-specific, pwsh-not-required, TL1
#
# #1608 emergency: a dedicated WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY / _WORKTREE_OFF_EMERGENCY
# sentinel bypasses Phase1 examination (human-only, audited). Mechanism: the shim's normal-OFF
# DQ/LOOKSLIKE regexes do NOT match the emergency string, so it flows past the token gate even
# when the examiner is broken (token fail-CLOSED). enforce-override-handlers still creates the
# marker and records an emergency audit entry.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
PATTERNS_NODE="$_AGENTS_DIR_NODE/hooks/lib/sentinel-patterns.js"
HANDLER_NODE="$_AGENTS_DIR_NODE/hooks/workflow-mark/enforce-override-handlers.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
SHIM="$AGENTS_DIR/hooks/supervisor-off-proposal-shim.js"
DETECT_NODE="$_AGENTS_DIR_NODE/hooks/supervisor-guard/detect.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'emerg'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

EMERG_WF='echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY: examiner broken, urgent escape>>"'
NORMAL_WF='echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: normal reason here>>"'

# ===== E1: emergency DQ regexes defined + match emergency, reject normal =====
run_E1() {
    local out
    out=$("$RWT" 10 node -e "
const p=require('$PATTERNS_NODE');
const dq=p.ENFORCE_WORKFLOW_OFF_EMERGENCY_RE_DQ, wdq=p.ENFORCE_WORKTREE_OFF_EMERGENCY_RE_DQ;
if(!dq||!wdq){process.stdout.write('MISSING');process.exit(0);}
const emerg=process.argv[1], normal=process.argv[2];
const ok = dq.test(emerg) && !dq.test(normal);
process.stdout.write(ok?'OK':'BADMATCH');
" "$EMERG_WF" "$NORMAL_WF" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "E1: EMERGENCY DQ regex matches emergency echo and rejects normal OFF"
    else
        fail "E1: RED-EXPECTED (regex not defined): emergency DQ regex missing/wrong; got ${out:-<err>}"
    fi
}

# ===== E2: isSentinel recognizes emergency sentinel =====
run_E2() {
    local out
    out=$("$RWT" 10 node -e "
const p=require('$PATTERNS_NODE');
process.stdout.write(p.isSentinel(process.argv[1])?'YES':'NO');" "$EMERG_WF" 2>/dev/null)
    if [ "$out" = "YES" ]; then
        pass "E2: isSentinel() recognizes the emergency sentinel"
    else
        fail "E2: RED-EXPECTED: isSentinel() does not yet recognize emergency sentinel; got ${out:-<err>}"
    fi
}

# ===== E3: normal-OFF strict DQ does NOT confuse emergency (non-confusion; regression guard) =====
run_E3() {
    local out
    out=$("$RWT" 10 node -e "
const p=require('$PATTERNS_NODE');
process.stdout.write(p.ENFORCE_WORKFLOW_OFF_RE_DQ.test(process.argv[1])?'CONFUSED':'DISTINCT');" "$EMERG_WF" 2>/dev/null)
    if [ "$out" = "DISTINCT" ]; then
        pass "E3: normal ENFORCE_WORKFLOW_OFF_RE_DQ does NOT match the emergency string"
    else
        fail "E3: normal OFF regex confuses emergency (${out:-<err>}) — greedy-match hazard"
    fi
}

# ===== E4: shim passes emergency through exit 0 even with error findings + no token (Phase1 bypass) =====
run_E4() {
    local tmp tn rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    WORKFLOW_PLANS_DIR="$tn" "$RWT" 10 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('emsid');
st.layer1.findings=[{categories:['code'],severity:'error',detail:'blocking',reporter:'workflow-gate',timestamp:new Date().toISOString()}];
fs.writeFileSync(w.getStatePath('emsid'),JSON.stringify(st));" >/dev/null 2>&1
    local hook_input
    hook_input=$("$RWT" 8 node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'emsid',tool_input:{command:process.argv[1]}}))" "$EMERG_WF")
    out=$(WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" AGENTS_CONFIG_DIR="$tn" "$RWT" 12 node "$SHIM" <<< "$hook_input" 2>/dev/null)
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" = "0" ] && ! echo "$out" | grep -q '"decision":"block"'; then
        pass "E4: emergency sentinel bypasses shim token gate (exit 0 despite error findings + no token)"
    else
        fail "E4: emergency must bypass Phase1 (exit 0); rc=$rc out=$out"
    fi
}

# ===== E5: enforce-override-handlers processes emergency → marker + emergency audit =====
run_E5() {
    local tmp tn marker
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" "$RWT" 12 node -e "
const h=require('$HANDLER_NODE');
h.handle({cmd:process.argv[1],sessionId:'emsid',pushMessage:()=>{},signalFatal:()=>{}});" "$EMERG_WF" >/dev/null 2>&1
    marker="$tmp/emsid.workflow-off"
    if [ -f "$marker" ]; then
        pass "E5a: emergency sentinel creates the .workflow-off marker"
    else
        fail "E5a: RED-EXPECTED (handler lacks emergency branch): marker not created"
    fi
    if grep -rq 'emergency' "$tmp"/*-supervisor-state.json 2>/dev/null; then
        pass "E5b: emergency activation records an emergency audit finding"
    else
        fail "E5b: RED-EXPECTED: emergency audit finding not recorded"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ===== E6: settings.json ask registers the emergency sentinel (human-only) =====
run_E6() {
    local out
    out=$("$RWT" 10 node -e "
const s=require('$_AGENTS_DIR_NODE/settings.json');
const ask=(s.permissions&&s.permissions.ask)||[];
process.stdout.write(ask.some(x=>/ENFORCE_WORKFLOW_OFF_EMERGENCY/.test(x))&&ask.some(x=>/ENFORCE_WORKTREE_OFF_EMERGENCY/.test(x))?'YES':'NO');" 2>/dev/null)
    if [ "$out" = "YES" ]; then
        pass "E6: settings.json ask registers both emergency sentinels (human approval gate)"
    else
        fail "E6: RED-EXPECTED: settings.json ask missing emergency sentinel entries; got ${out:-<err>}"
    fi
}

run_E1
run_E2
run_E3
run_E4
run_E5
run_E6

# ===== Section A: detectOffProposal EMERGENCY wiring (hooks/supervisor-guard/detect.js) =====
# detectOffProposal must recognize the *_EMERGENCY_* OFF forms as OFF proposals (the normal
# OFF regexes do not match them), and still honor a later matching ON as a cancel, and still
# apply the workflow-off > worktree-off precedence when both are live.
# build a JSONL transcript (one assistant Bash tool_use per command arg) then run detectOffProposal.
detect_off_json() {  # <cmd>...  → prints JSON result of detectOffProposal
    local tmp f fn c
    tmp=$(make_tmp); f="$tmp/t.jsonl"; : > "$f"
    for c in "$@"; do
        node -e 'process.stdout.write(JSON.stringify({type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:process.argv[1]}}]}})+"\n")' "$c" >> "$f"
    done
    fn=$(node_path "$f")
    "$RWT" 10 node -e "const m=require('$DETECT_NODE');process.stdout.write(JSON.stringify(m.detectOffProposal('$fn')));" 2>/dev/null
    rm -rf "$tmp" 2>/dev/null || true
}
assert_json() {  # <name> <want-json> <got-json>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — want=$2 got=${3:-<err>}"; fi
}

run_A1() { assert_json "A1: WORKFLOW_OFF_EMERGENCY → {detected:true,kind:workflow-off}" \
    '{"detected":true,"kind":"workflow-off"}' \
    "$(detect_off_json 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY: examiner broken, urgent escape>>"')"; }
run_A2() { assert_json "A2: WORKTREE_OFF_EMERGENCY → {detected:true,kind:worktree-off}" \
    '{"detected":true,"kind":"worktree-off"}' \
    "$(detect_off_json 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF_EMERGENCY: guard false block>>"')"; }
run_A3() { assert_json "A3: WORKFLOW_OFF_EMERGENCY then later WORKFLOW_ON cancels → not detected" \
    '{"detected":false,"kind":null}' \
    "$(detect_off_json 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY: broke>>"' 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: restored>>"')"; }
run_A4() { assert_json "A4: WORKTREE_OFF_EMERGENCY then later WORKTREE_ON cancels → not detected" \
    '{"detected":false,"kind":null}' \
    "$(detect_off_json 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF_EMERGENCY: broke>>"' 'echo "<<WORKFLOW_ENFORCE_WORKTREE_ON: restored>>"')"; }
run_A5() { assert_json "A5: no off sentinel → not detected (false-positive guard)" \
    '{"detected":false,"kind":null}' \
    "$(detect_off_json 'git status' 'echo hello world')"; }
run_A6() { assert_json "A6: normal WORKFLOW_OFF + WORKTREE_OFF_EMERGENCY, neither cancelled → workflow-off wins" \
    '{"detected":true,"kind":"workflow-off"}' \
    "$(detect_off_json 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF_EMERGENCY: guard>>"' 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: normal reason here>>"')"; }

run_A1
run_A2
run_A3
run_A4
run_A5
run_A6

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
