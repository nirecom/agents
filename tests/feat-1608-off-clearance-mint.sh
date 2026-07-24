#!/usr/bin/env bash
# tests/feat-1608-off-clearance-mint.sh
# Tests: bin/request-off-clearance, hooks/lib/supervisor-state-schema.js, hooks/lib/supervisor-state-writer.js, hooks/workflow-mark/enforce-override-handlers.js, hooks/workflow-mark/enforce-override-handlers/off-clearance.js, hooks/lib/resolve-workflow-session-id.js
# Tags: off-clearance, mint, examination, audit, single-use, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Real codex subprocess examination via a live claude -p session (here the examiner
#   is stubbed on PATH / the bin script drives it) and real PreToolUse/PostToolUse firing.
# - Real time-boxed foreground Bash timeout behavior of bin/request-off-clearance.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
HANDLER_NODE="$_AGENTS_DIR_NODE/hooks/workflow-mark/enforce-override-handlers.js"
REQ="$AGENTS_DIR/bin/request-off-clearance"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'mint1608'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# ===== A: schema permits off_examination + off_clearance_consumed record_types =====
run_A() {
    local out
    out=$("$RWT" 10 node -e "
const s=require('$SCHEMA_NODE');
const v=s.RECORD_TYPE_VALUES||[];
process.stdout.write((v.includes('off_examination')&&v.includes('off_clearance_consumed'))?'YES':'NO:'+v.join(','));" 2>/dev/null)
    if [ "$out" = "YES" ]; then
        pass "A: supervisor-state-schema RECORD_TYPE_VALUES includes off_examination + off_clearance_consumed"
    else
        fail "A: RED-EXPECTED (schema not extended): record_types missing; got $out"
    fi
}

# ===== B: appendFinding actually persists an off_examination finding (not silently dropped) =====
run_B() {
    local tmp tn out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    out=$(WORKFLOW_PLANS_DIR="$tn" "$RWT" 12 node -e "
const w=require('$WRITER_NODE');
const ok=w.appendFinding('bsid',{categories:['workflow'],severity:'notice',detail:'examination reason=x cat=workflow-bug verdict=ALLOW',reporter:'off-clearance-examiner',record_type:'off_examination'});
const st=w.readState('bsid');
const has=st&&st.layer1&&st.layer1.findings.some(f=>f.record_type==='off_examination');
process.stdout.write((ok&&has)?'PERSISTED':'DROPPED');" 2>/dev/null)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "PERSISTED" ]; then
        pass "B: appendFinding persists an off_examination audit finding"
    else
        fail "B: RED-EXPECTED (schema rejects record_type): off_examination finding silently dropped; got $out"
    fi
}

# ===== bin/request-off-clearance cases (script does examination+mint+audit — 実装時要件2) =====
mint_available() { [ -x "$REQ" ] || [ -f "$REQ" ]; }

# build a fake examiner PATH stub emitting a fixed verdict, and run the script.
# run_req <tmp_node> <sid> <verdict-kind: allow|reject|absent> <extra args...> → prints "rc|<combined output>"
run_req() {
    local tn="$1" sid="$2" kind="$3"; shift 3
    local stubbin; stubbin=$(make_tmp)
    if [ "$kind" = "allow" ]; then
        printf '#!/usr/bin/env bash\necho "{\\"verdict\\":\\"ALLOW\\",\\"reason\\":\\"legit workflow bug\\"}"\nexit 0\n' > "$stubbin/codex"
    elif [ "$kind" = "reject" ]; then
        printf '#!/usr/bin/env bash\necho "{\\"verdict\\":\\"REJECT\\",\\"reason\\":\\"use /sweep-worktrees\\"}"\nexit 0\n' > "$stubbin/codex"
    else
        printf '#!/usr/bin/env bash\nexit 1\n' > "$stubbin/codex"   # unavailable/failure
    fi
    chmod +x "$stubbin/codex"
    local out rc
    out=$(PATH="$stubbin:$PATH" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" WORKFLOW_PLANS_DIR="$tn" \
        CLAUDE_WORKFLOW_DIR="$tn" SESSION_ID="$sid" CLAUDE_CODE_SESSION_ID="$sid" \
        "$RWT" 40 bash "$REQ" "$@" 2>&1)
    rc=$?
    rm -rf "$stubbin" 2>/dev/null || true
    printf '%s|%s' "$rc" "$out"
}
token_count() { ls "$1"/*.off-clearance 2>/dev/null | wc -l | tr -d ' '; }
state_has() { grep -rq "$2" "$1"/*-supervisor-state.json 2>/dev/null; }

# ===== C: codex ALLOW → token minted (target/category/expires_at) + reason-binding guidance =====
run_C() {
    if ! mint_available; then
        fail "C: RED-EXPECTED (not yet created): bin/request-off-clearance missing → no ALLOW mint path"
        return
    fi
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    r=$(run_req "$tn" "csid" allow --target workflow --category workflow-bug --urgency normal --detail "next-step bug"); rc="${r%%|*}"; out="${r#*|}"
    if [ "$(token_count "$tmp")" -ge 1 ]; then
        pass "C1: codex ALLOW → <sid>.off-clearance token minted"
    else
        fail "C1: RED-EXPECTED: ALLOW verdict did not mint a token; rc=$rc out=$out"
    fi
    if ls "$tmp"/*.off-clearance >/dev/null 2>&1 && grep -q '"category"' "$tmp"/*.off-clearance 2>/dev/null && grep -q '"expires_at"' "$tmp"/*.off-clearance 2>/dev/null; then
        pass "C2: minted token carries category + expires_at (reason-bound schema)"
    else
        fail "C2: RED-EXPECTED: token schema fields (category/expires_at) absent"
    fi
    if echo "$out" | grep -qiE '\[workflow-bug\]|\[category\]|include .*category'; then
        pass "C3: ALLOW guidance instructs embedding [category] in the OFF sentinel reason"
    else
        fail "C3: RED-EXPECTED: ALLOW guidance missing reason-binding instruction; out=$out"
    fi
    if state_has "$tmp" "off_examination"; then
        pass "C4: examination appended off_examination audit finding (ALLOW)"
    else
        fail "C4: RED-EXPECTED: off_examination audit finding not recorded on ALLOW"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ===== D: codex REJECT → no token + rejection reason/alternative + audit =====
run_D() {
    if ! mint_available; then
        fail "D: RED-EXPECTED (not yet created): bin/request-off-clearance missing → no REJECT path"
        return
    fi
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    r=$(run_req "$tn" "dsid" reject --target worktree --category cleanup --detail "just cleaning up"); rc="${r%%|*}"; out="${r#*|}"
    if [ "$(token_count "$tmp")" -eq 0 ]; then
        pass "D1: codex REJECT → NO token minted"
    else
        fail "D1: REJECT must not mint a token"
    fi
    if echo "$out" | grep -qiE 'reject|sweep-worktrees|alternative|not.*grant'; then
        pass "D2: REJECT surfaces rejection reason / alternative"
    else
        fail "D2: RED-EXPECTED: REJECT output missing rejection/alternative guidance; out=$out"
    fi
    if state_has "$tmp" "off_examination"; then
        pass "D3: examination appended off_examination audit finding (REJECT recorded too)"
    else
        fail "D3: RED-EXPECTED: off_examination audit finding not recorded on REJECT"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ===== E: codex unavailable → no token + emergency-sentinel guidance =====
run_E() {
    if ! mint_available; then
        fail "E: RED-EXPECTED (not yet created): bin/request-off-clearance missing → no unavailable path"
        return
    fi
    local tmp tn r rc out
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    r=$(run_req "$tn" "esid" absent --target workflow --category workflow-bug --detail "bug"); rc="${r%%|*}"; out="${r#*|}"
    if [ "$(token_count "$tmp")" -eq 0 ]; then
        pass "E1: codex unavailable → NO token minted"
    else
        fail "E1: unavailable examiner must not mint a token"
    fi
    if echo "$out" | grep -qiE 'EMERGENCY|emergency'; then
        pass "E2: unavailable path points at the emergency sentinel"
    else
        fail "E2: RED-EXPECTED: unavailable path missing emergency-sentinel guidance; out=$out"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ===== F: single-use consumption — OFF activation unlinks token + appends off_clearance_consumed =====
run_F() {
    local tmp tn out consumed_ok token_gone
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    # seed a valid token
    "$RWT" 10 node -e "
const fs=require('fs'),path=require('path');
fs.writeFileSync(path.join('$tn','fsid.off-clearance'),JSON.stringify({target:'workflow',category:'workflow-bug',expires_at:new Date(Date.now()+900000).toISOString()}));" >/dev/null 2>&1
    # drive the OFF marker activation via enforce-override-handlers
    WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" "$RWT" 15 node -e "
const h=require('$HANDLER_NODE');
h.handle({cmd:'echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: [workflow-bug] next-step bug>>\"',sessionId:'fsid',pushMessage:()=>{},signalFatal:()=>{}});" >/dev/null 2>&1
    token_gone=no; [ ! -f "$tmp/fsid.off-clearance" ] && token_gone=yes
    if [ "$token_gone" = "yes" ]; then
        pass "F1: OFF activation atomically consumes (unlinks) the clearance token (single-use)"
    else
        fail "F1: RED-EXPECTED: token not consumed on OFF activation (reuse hole open)"
    fi
    if state_has "$tmp" "off_clearance_consumed"; then
        pass "F2: consumption appends off_clearance_consumed audit finding"
    else
        fail "F2: RED-EXPECTED: off_clearance_consumed audit finding not recorded"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ===== consumeOffClearance direct + wsid-fallback (single-use unlink + audit) =====
OFFCLR_NODE="$_AGENTS_DIR_NODE/hooks/workflow-mark/enforce-override-handlers/off-clearance.js"

# seed_valid_token <tmp_node> <sid>
seed_valid_token() {
    "$RWT" 10 node -e "
const fs=require('fs'),path=require('path');
fs.writeFileSync(path.join('$1','$2'+'.off-clearance'),JSON.stringify({target:'workflow',category:'workflow-bug',expires_at:new Date(Date.now()+900000).toISOString()}));" >/dev/null 2>&1
}

# CO-1 (D1): direct-sid consume — token for the passed sessionId is unlinked + audited under that sid
run_CO1() {
    local tmp tn
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    seed_valid_token "$tn" "co1sid"
    WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" CLAUDE_CODE_SESSION_ID="" SESSION_ID="" \
        "$RWT" 15 node -e "require('$OFFCLR_NODE').consumeOffClearance('workflow','co1sid');" >/dev/null 2>&1
    local ok=1
    [ -f "$tmp/co1sid.off-clearance" ] && ok=0
    grep -q "off_clearance_consumed" "$tmp/co1sid-supervisor-state.json" 2>/dev/null || ok=0
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "CO-1: consumeOffClearance(direct sid) unlinks token + appends off_clearance_consumed under that sid"
    else
        fail "CO-1: RED-EXPECTED: direct-sid consume did not unlink token / record audit"
    fi
}

# CO-2 (D2): wsid-fallback consume — token keyed only to the resolved workflow sid (WORKTREE_NOTES.md)
run_CO2() {
    local tmp tn cwdd
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    cwdd=$(make_tmp)
    printf 'Session-ID: co2wsid\n' > "$cwdd/WORKTREE_NOTES.md"
    seed_valid_token "$tn" "co2wsid"   # token keyed to the WSID only, NOT to co2sid
    ( cd "$cwdd" && WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" CLAUDE_CODE_SESSION_ID="" SESSION_ID="" \
        "$RWT" 15 node -e "require('$OFFCLR_NODE').consumeOffClearance('workflow','co2sid');" >/dev/null 2>&1 )
    local ok=1
    [ -f "$tmp/co2wsid.off-clearance" ] && ok=0                       # fallback token consumed
    grep -q "off_clearance_consumed" "$tmp/co2wsid-supervisor-state.json" 2>/dev/null || ok=0  # audit under WSID
    [ -f "$tmp/co2sid-supervisor-state.json" ] && ok=0               # NOT under the direct sid
    rm -rf "$tmp" "$cwdd" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "CO-2: consumeOffClearance falls back to resolved WSID token, unlinks it + audits under the WSID"
    else
        fail "CO-2: RED-EXPECTED: wsid-fallback consume did not mirror the fallback-keyed token"
    fi
}

# CO-3 (D3): neither direct nor fallback token present → no-op (no crash, no spurious state file)
run_CO3() {
    local tmp tn rc
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    ( cd "$tmp" && WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" CLAUDE_CODE_SESSION_ID="" SESSION_ID="" \
        "$RWT" 15 node -e "require('$OFFCLR_NODE').consumeOffClearance('workflow','co3sid');" >/dev/null 2>&1 )
    rc=$?
    local ok=1
    [ "$rc" -ne 0 ] && ok=0                                    # fail-open: absent token must not throw
    ls "$tmp"/*-supervisor-state.json >/dev/null 2>&1 && ok=0  # no audit finding written for a no-op
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "CO-3: consumeOffClearance with no token present is a fail-open no-op (no crash, no audit entry)"
    else
        fail "CO-3: RED-EXPECTED: absent-token consume must be a silent no-op; rc=$rc"
    fi
}

# ===== request-off-clearance examiner robustness (custom codex stubs — never real codex) =====
# exec_req <tmp_node> <sid> <codex-stub-body> <req-args...> → prints "rc|<combined output>"
exec_req() {
    local tn="$1" sid="$2" body="$3"; shift 3
    local stubbin out rc
    stubbin=$(make_tmp)
    printf '%s' "$body" > "$stubbin/codex"
    chmod +x "$stubbin/codex"
    out=$(PATH="$stubbin:$PATH" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" WORKFLOW_PLANS_DIR="$tn" \
        CLAUDE_WORKFLOW_DIR="$tn" SESSION_ID="$sid" CLAUDE_CODE_SESSION_ID="$sid" \
        "$RWT" 40 bash "$REQ" "$@" 2>&1)
    rc=$?
    rm -rf "$stubbin" 2>/dev/null || true
    printf '%s|%s' "$rc" "$out"
}

# EX-1: preamble + decoy REJECT object + ALLOW object + trailing prose → LAST object wins → mint
run_EX1() {
    if ! mint_available; then fail "EX-1: RED-EXPECTED (script missing)"; return; fi
    local tmp tn r out body
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    body='#!/usr/bin/env bash
echo "Analysis: considering the request in detail."
echo "{\"verdict\":\"REJECT\",\"reason\":\"decoy earlier object must be ignored\"}"
echo "{\"verdict\":\"ALLOW\",\"reason\":\"legitimate workflow bug on second thought\"}"
echo "Examination complete, thank you."
exit 0
'
    r=$(exec_req "$tn" "ex1sid" "$body" --target workflow --category workflow-bug --detail "next-step bug"); out="${r#*|}"
    if [ "$(token_count "$tmp")" -ge 1 ]; then
        pass "EX-1: trailing prose + decoy object — parser takes the LAST JSON object (ALLOW) → token minted"
    else
        fail "EX-1: RED-EXPECTED: last-object-wins parse failed to mint on ALLOW; out=$out"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# EX-2: ALLOW-looking JSON on stderr + REJECT on stdout → stdout wins → NO token (stderr can't supply a verdict)
run_EX2() {
    if ! mint_available; then fail "EX-2: RED-EXPECTED (script missing)"; return; fi
    local tmp tn r out body
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    body='#!/usr/bin/env bash
echo "{\"verdict\":\"ALLOW\",\"reason\":\"sneaky verdict on stderr\"}" >&2
echo "{\"verdict\":\"REJECT\",\"reason\":\"the real stdout verdict\"}"
exit 0
'
    r=$(exec_req "$tn" "ex2sid" "$body" --target workflow --category workflow-bug --detail "bug"); out="${r#*|}"
    if [ "$(token_count "$tmp")" -eq 0 ]; then
        pass "EX-2: verdict on stderr is ignored; stdout REJECT governs → NO token minted"
    else
        fail "EX-2: RED-EXPECTED: stderr must not be able to supply an ALLOW verdict; out=$out"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# EX-3: stdout carries no parseable JSON object → empty verdict → REJECT → NO token
run_EX3() {
    if ! mint_available; then fail "EX-3: RED-EXPECTED (script missing)"; return; fi
    local tmp tn r out body
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    body='#!/usr/bin/env bash
echo "I was unable to reach a decision. There is no JSON here at all."
exit 0
'
    r=$(exec_req "$tn" "ex3sid" "$body" --target workflow --category workflow-bug --detail "bug"); out="${r#*|}"
    local ok=1
    [ "$(token_count "$tmp")" -eq 0 ] || ok=0
    echo "$out" | grep -qiE 'REJECT|no.*parseable|no clearance token' || ok=0
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "EX-3: unparseable examiner stdout → REJECT (no verdict) → NO token minted"
    else
        fail "EX-3: RED-EXPECTED: unparseable stdout must default to REJECT/no-token; out=$out"
    fi
}

# EX-4: examiner exits 124 (timeout kill) → REJECT timeout path → NO token + off_examination audit
run_EX4() {
    if ! mint_available; then fail "EX-4: RED-EXPECTED (script missing)"; return; fi
    local tmp tn r out body
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    body='#!/usr/bin/env bash
exit 124
'
    r=$(exec_req "$tn" "ex4sid" "$body" --target worktree --category cleanup --detail "cleanup"); out="${r#*|}"
    local ok=1
    [ "$(token_count "$tmp")" -eq 0 ] || ok=0
    echo "$out" | grep -qiE 'timed out|REJECT' || ok=0
    state_has "$tmp" "off_examination" || ok=0
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "EX-4: examiner exit 124 → REJECT (timeout) → NO token + off_examination audit recorded"
    else
        fail "EX-4: RED-EXPECTED: exit-124 must map to REJECT/no-token with an audit entry; out=$out"
    fi
}

# EX-5: run a copy of the script whose SCRIPT_DIR lacks run-with-timeout.sh → UNAVAILABLE → NO token
run_EX5() {
    if ! mint_available; then fail "EX-5: RED-EXPECTED (script missing)"; return; fi
    local tmp tn bindir stubbin r out rc
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    bindir=$(make_tmp)                       # copy of the script only — NO run-with-timeout.sh sibling
    cp "$REQ" "$bindir/request-off-clearance"
    chmod +x "$bindir/request-off-clearance"
    stubbin=$(make_tmp)                       # working codex on PATH so the wrapper check (not codex) is what fails
    printf '#!/usr/bin/env bash\necho "{\\"verdict\\":\\"ALLOW\\",\\"reason\\":\\"would-allow but wrapper missing\\"}"\nexit 0\n' > "$stubbin/codex"
    chmod +x "$stubbin/codex"
    out=$(PATH="$stubbin:$PATH" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" WORKFLOW_PLANS_DIR="$tn" \
        CLAUDE_WORKFLOW_DIR="$tn" SESSION_ID="ex5sid" CLAUDE_CODE_SESSION_ID="ex5sid" \
        bash "$bindir/request-off-clearance" --target workflow --category workflow-bug --detail "bug" 2>&1)
    rc=$?
    local ok=1
    [ "$(token_count "$tmp")" -eq 0 ] || ok=0
    echo "$out" | grep -qiE 'unavailable|timeout wrapper' || ok=0
    [ "$rc" -ne 0 ] || ok=0
    rm -rf "$tmp" "$bindir" "$stubbin" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "EX-5: missing timeout wrapper → examiner UNAVAILABLE → NO token (even with a working codex)"
    else
        fail "EX-5: RED-EXPECTED: absent run-with-timeout.sh must yield UNAVAILABLE/no-token; rc=$rc out=$out"
    fi
}

run_A
run_B
run_C
run_D
run_E
run_F
run_CO1
run_CO2
run_CO3
run_EX1
run_EX2
run_EX3
run_EX4
run_EX5

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
