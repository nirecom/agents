#!/bin/bash
# tests/refactor-1202-supervisor-guard-split/behavioral.sh
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

DETECT_JS="${_AGENTS_DIR_NODE}/hooks/supervisor-guard/detect.js"
DETECT_PATH="${AGENTS_DIR}/hooks/supervisor-guard/detect.js"

if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not on PATH"
    exit 0
fi

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# ─── GROUP C — positive-trigger behavioral tests ──────────────────────────────

# 25. detectSentinelHang — positive: MARK_STEP as last tool_use → true
if [ ! -f "$DETECT_PATH" ]; then skip "detectSentinelHang positive (detect.js missing)"
else
    _f=$(mktemp); printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo \"<<WORKFLOW_MARK_STEP_write_code_complete>>\""}}]}}' > "$_f"
    out=$(run_with_timeout 10 node -e "const m=require('${DETECT_JS}');const r=m.detectSentinelHang('$(to_node_path "$_f")');if(r!==true){console.log('FAIL: expected true, got '+r);process.exit(1);}console.log('OK');" 2>&1); rm -f "$_f"
    if [ "$out" = "OK" ]; then pass "detectSentinelHang positive: MARK_STEP as last tool_use → true"
    else fail "detectSentinelHang positive: MARK_STEP as last tool_use → true" "$out"; fi
fi

# 26. detectSentinelHang — negative: MARK_STEP followed by another tool_use → false
if [ ! -f "$DETECT_PATH" ]; then skip "detectSentinelHang negative: MARK_STEP + subsequent tool_use (detect.js missing)"
else
    _f=$(mktemp); printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo \"<<WORKFLOW_MARK_STEP_write_code_complete>>\""}},{"type":"tool_use","name":"Read","input":{}}]}}' > "$_f"
    out=$(run_with_timeout 10 node -e "const m=require('${DETECT_JS}');const r=m.detectSentinelHang('$(to_node_path "$_f")');if(r!==false){console.log('FAIL: expected false, got '+r);process.exit(1);}console.log('OK');" 2>&1); rm -f "$_f"
    if [ "$out" = "OK" ]; then pass "detectSentinelHang negative: MARK_STEP + subsequent tool_use → false"
    else fail "detectSentinelHang negative: MARK_STEP + subsequent tool_use → false" "$out"; fi
fi

# 27. detectAskUserQuestionTurn — positive: last tool_use is AskUserQuestion → true
if [ ! -f "$DETECT_PATH" ]; then skip "detectAskUserQuestionTurn positive (detect.js missing)"
else
    _f=$(mktemp); printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{}}]}}' > "$_f"
    out=$(run_with_timeout 10 node -e "const m=require('${DETECT_JS}');const r=m.detectAskUserQuestionTurn('$(to_node_path "$_f")');if(r!==true){console.log('FAIL: expected true, got '+r);process.exit(1);}console.log('OK');" 2>&1); rm -f "$_f"
    if [ "$out" = "OK" ]; then pass "detectAskUserQuestionTurn positive: last tool_use is AskUserQuestion → true"
    else fail "detectAskUserQuestionTurn positive: last tool_use is AskUserQuestion → true" "$out"; fi
fi

# 28. detectAskUserQuestionTurn — negative: last tool_use is NOT AskUserQuestion → false
if [ ! -f "$DETECT_PATH" ]; then skip "detectAskUserQuestionTurn negative (detect.js missing)"
else
    _f=$(mktemp); printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}' > "$_f"
    out=$(run_with_timeout 10 node -e "const m=require('${DETECT_JS}');const r=m.detectAskUserQuestionTurn('$(to_node_path "$_f")');if(r!==false){console.log('FAIL: expected false, got '+r);process.exit(1);}console.log('OK');" 2>&1); rm -f "$_f"
    if [ "$out" = "OK" ]; then pass "detectAskUserQuestionTurn negative: last tool_use not AskUserQuestion → false"
    else fail "detectAskUserQuestionTurn negative: last tool_use not AskUserQuestion → false" "$out"; fi
fi

# 29. detectOffProposal — positive worktree-off → {detected:true, kind:'worktree-off'}
if [ ! -f "$DETECT_PATH" ]; then skip "detectOffProposal positive worktree-off (detect.js missing)"
else
    _f=$(mktemp); printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: reason>>\""}}]}}' > "$_f"
    out=$(run_with_timeout 10 node -e "const m=require('${DETECT_JS}');const r=m.detectOffProposal('$(to_node_path "$_f")');if(!r||r.detected!==true||r.kind!=='worktree-off'){console.log('FAIL: expected {detected:true,kind:worktree-off}, got '+JSON.stringify(r));process.exit(1);}console.log('OK');" 2>&1); rm -f "$_f"
    if [ "$out" = "OK" ]; then pass "detectOffProposal positive: ENFORCE_WORKTREE_OFF → {detected:true,kind:'worktree-off'}"
    else fail "detectOffProposal positive: ENFORCE_WORKTREE_OFF → {detected:true,kind:'worktree-off'}" "$out"; fi
fi

# 30. parseTranscriptForAudit — positive: 2 assistant entries → array of length 2
if [ ! -f "$DETECT_PATH" ]; then skip "parseTranscriptForAudit positive: 2 entries → length 2 (detect.js missing)"
else
    _f=$(mktemp); printf '%s\n' '{"type":"assistant","message":{"content":"turn 1"}}' '{"type":"assistant","message":{"content":"turn 2"}}' > "$_f"
    out=$(run_with_timeout 10 node -e "const m=require('${DETECT_JS}');const r=m.parseTranscriptForAudit('$(to_node_path "$_f")');if(!Array.isArray(r)||r.length!==2){console.log('FAIL: expected array of length 2, got '+JSON.stringify(r));process.exit(1);}console.log('OK');" 2>&1); rm -f "$_f"
    if [ "$out" = "OK" ]; then pass "parseTranscriptForAudit positive: 2 assistant entries → array of length 2"
    else fail "parseTranscriptForAudit positive: 2 assistant entries → array of length 2" "$out"; fi
fi

# 31. detectOffProposal — positive workflow-off → {detected:true, kind:'workflow-off'}
if [ ! -f "$DETECT_PATH" ]; then skip "detectOffProposal positive workflow-off (detect.js missing)"
else
    _f=$(mktemp); printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: reason>>\""}}]}}' > "$_f"
    out=$(run_with_timeout 10 node -e "const m=require('${DETECT_JS}');const r=m.detectOffProposal('$(to_node_path "$_f")');if(!r||r.detected!==true||r.kind!=='workflow-off'){console.log('FAIL: expected {detected:true,kind:workflow-off}, got '+JSON.stringify(r));process.exit(1);}console.log('OK');" 2>&1); rm -f "$_f"
    if [ "$out" = "OK" ]; then pass "detectOffProposal positive: ENFORCE_WORKFLOW_OFF → {detected:true,kind:'workflow-off'}"
    else fail "detectOffProposal positive: ENFORCE_WORKFLOW_OFF → {detected:true,kind:'workflow-off'}" "$out"; fi
fi

# 32. detectOffProposal — OFF+ON cancel path → {detected:false}
if [ ! -f "$DETECT_PATH" ]; then skip "detectOffProposal OFF+ON cancel path (detect.js missing)"
else
    _f=$(mktemp)
    printf '%s\n' \
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: reason>>\""}}]}}' \
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_ON: reason>>\""}}]}}' \
        > "$_f"
    out=$(run_with_timeout 10 node -e "const m=require('${DETECT_JS}');const r=m.detectOffProposal('$(to_node_path "$_f")');if(!r||r.detected!==false){console.log('FAIL: expected {detected:false}, got '+JSON.stringify(r));process.exit(1);}console.log('OK');" 2>&1); rm -f "$_f"
    if [ "$out" = "OK" ]; then pass "detectOffProposal OFF+ON cancel path: WORKTREE_OFF then WORKTREE_ON → {detected:false}"
    else fail "detectOffProposal OFF+ON cancel path: WORKTREE_OFF then WORKTREE_ON → {detected:false}" "$out"; fi
fi

# 33. detectSentinelHang — exempt step: MARK_STEP_final_report_complete → false
if [ ! -f "$DETECT_PATH" ]; then skip "detectSentinelHang exempt step final_report (detect.js missing)"
else
    _f=$(mktemp); printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo \"<<WORKFLOW_MARK_STEP_final_report_complete>>\""}}]}}' > "$_f"
    out=$(run_with_timeout 10 node -e "const m=require('${DETECT_JS}');const r=m.detectSentinelHang('$(to_node_path "$_f")');if(r!==false){console.log('FAIL: expected false (exempt step), got '+r);process.exit(1);}console.log('OK');" 2>&1); rm -f "$_f"
    if [ "$out" = "OK" ]; then pass "detectSentinelHang exempt step: MARK_STEP_final_report_complete → false (exempt)"
    else fail "detectSentinelHang exempt step: MARK_STEP_final_report_complete → false (exempt)" "$out"; fi
fi

# ─── GROUP D — boundary / shape / undefined-path tests ───────────────────────

# 34. detectSentinelHang — tail-100 boundary: MARK_STEP only in line 1 of 200 → false
if [ ! -f "$DETECT_PATH" ]; then skip "detectSentinelHang tail-100 boundary: MARK_STEP outside window → false (detect.js missing)"
else
    _f=$(mktemp); _fn="$(to_node_path "$_f")"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo \"<<WORKFLOW_MARK_STEP_write_code_complete>>\""}}]}}' > "$_f"
    for i in $(seq 2 200); do printf '%s\n' '{"type":"user","message":"padding"}' >> "$_f"; done
    out=$(run_with_timeout 10 node -e "const m=require('${DETECT_JS}');const r=m.detectSentinelHang('${_fn}');if(r!==false){console.log('FAIL: expected false (MARK_STEP outside tail-100), got '+r);process.exit(1);}console.log('OK');" 2>&1); rm -f "$_f"
    if [ "$out" = "OK" ]; then pass "detectSentinelHang tail-100 boundary: MARK_STEP only in line 1 of 200-line transcript → false"
    else fail "detectSentinelHang tail-100 boundary: MARK_STEP only in line 1 of 200-line transcript → false" "$out"; fi
fi

# 35. detectOffProposal — whole-transcript scan: ENFORCE_WORKTREE_OFF in line 1 of 200 → {detected:true}
if [ ! -f "$DETECT_PATH" ]; then skip "detectOffProposal whole-transcript scan: OFF in line 1 of 200 → detected (detect.js missing)"
else
    _f=$(mktemp); _fn="$(to_node_path "$_f")"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: reason>>\""}}]}}' > "$_f"
    for i in $(seq 2 200); do printf '%s\n' '{"type":"user","message":"padding"}' >> "$_f"; done
    out=$(run_with_timeout 10 node -e "const m=require('${DETECT_JS}');const r=m.detectOffProposal('${_fn}');if(!r||r.detected!==true||r.kind!=='worktree-off'){console.log('FAIL: expected {detected:true,kind:worktree-off}, got '+JSON.stringify(r));process.exit(1);}console.log('OK');" 2>&1); rm -f "$_f"
    if [ "$out" = "OK" ]; then pass "detectOffProposal whole-transcript scan: ENFORCE_WORKTREE_OFF in line 1 of 200 → {detected:true,kind:'worktree-off'}"
    else fail "detectOffProposal whole-transcript scan: ENFORCE_WORKTREE_OFF in line 1 of 200 → {detected:true,kind:'worktree-off'}" "$out"; fi
fi

# 36. parseTranscriptForAudit — returned entries have shape {role:'assistant', content:...}
if [ ! -f "$DETECT_PATH" ]; then skip "parseTranscriptForAudit entry shape {role,content} (detect.js missing)"
else
    _f=$(mktemp); _fn="$(to_node_path "$_f")"
    printf '%s\n' '{"type":"assistant","message":{"content":"hello"}}' > "$_f"
    out=$(run_with_timeout 10 node -e "const m=require('${DETECT_JS}');const r=m.parseTranscriptForAudit('${_fn}');if(!Array.isArray(r)||r.length!==1||r[0].role!=='assistant'||r[0].content===undefined){console.log('FAIL: expected [{role:\"assistant\",content:...}], got '+JSON.stringify(r));process.exit(1);}console.log('OK');" 2>&1); rm -f "$_f"
    if [ "$out" = "OK" ]; then pass "parseTranscriptForAudit entry shape: single assistant entry → [{role:'assistant',content:...}]"
    else fail "parseTranscriptForAudit entry shape: single assistant entry → [{role:'assistant',content:...}]" "$out"; fi
fi

# 37. parseTranscriptForAudit — user-type lines excluded
if [ ! -f "$DETECT_PATH" ]; then skip "parseTranscriptForAudit excludes user-type lines (detect.js missing)"
else
    _f=$(mktemp); _fn="$(to_node_path "$_f")"
    printf '%s\n' '{"type":"user","message":{"content":"hi"}}' '{"type":"assistant","message":{"content":"hello"}}' > "$_f"
    out=$(run_with_timeout 10 node -e "const m=require('${DETECT_JS}');const r=m.parseTranscriptForAudit('${_fn}');if(!Array.isArray(r)||r.length!==1){console.log('FAIL: expected array of length 1 (user entry excluded), got '+JSON.stringify(r));process.exit(1);}console.log('OK');" 2>&1); rm -f "$_f"
    if [ "$out" = "OK" ]; then pass "parseTranscriptForAudit excludes user-type lines: user+assistant JSONL → array of length 1"
    else fail "parseTranscriptForAudit excludes user-type lines: user+assistant JSONL → array of length 1" "$out"; fi
fi

# 38. detectAskUserQuestionTurn — AskUserQuestion NOT last: [AskUserQuestion, Bash] → false
if [ ! -f "$DETECT_PATH" ]; then skip "detectAskUserQuestionTurn: AskUserQuestion not last tool_use → false (detect.js missing)"
else
    _f=$(mktemp); _fn="$(to_node_path "$_f")"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{}},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}' > "$_f"
    out=$(run_with_timeout 10 node -e "const m=require('${DETECT_JS}');const r=m.detectAskUserQuestionTurn('${_fn}');if(r!==false){console.log('FAIL: expected false (AskUserQuestion not last), got '+r);process.exit(1);}console.log('OK');" 2>&1); rm -f "$_f"
    if [ "$out" = "OK" ]; then pass "detectAskUserQuestionTurn: [AskUserQuestion, Bash] → false (last tool_use is Bash)"
    else fail "detectAskUserQuestionTurn: [AskUserQuestion, Bash] → false (last tool_use is Bash)" "$out"; fi
fi

# 39. detect.js module.exports has exactly 4 keys
if [ ! -f "$DETECT_PATH" ]; then skip "detect.js module.exports has exactly 4 keys (detect.js missing)"
else
    out=$(run_with_timeout 10 node -e "const m=require('${DETECT_JS}');if(Object.keys(m).length!==4){console.log('FAIL: expected 4 keys, got '+Object.keys(m).length+': '+Object.keys(m).join(', '));process.exit(1);}console.log('OK');" 2>&1)
    if [ "$out" = "OK" ]; then pass "detect.js module.exports has exactly 4 keys"
    else fail "detect.js module.exports has exactly 4 keys" "$out"; fi
fi

# ─── SUMMARY ─────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
