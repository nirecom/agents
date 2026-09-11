# shellcheck shell=bash
# Tests: hooks/lib/instructions-loaded-receipt.js, hooks/instructions-loaded-audit.js
# Tags: rules-injection, instructions-loaded, receipt, atomicity, idempotency, fail-open, TL2, scope:common

# Receipt shape, atomic publish, idempotency on a repeated key, and the fail-open
# contract.

# CONTRACT NOTE (asserted here): the receipt key is sha1(file_path), so a session
# that loads the SAME file repeatedly collides on ONE key by design. Repeated and
# concurrent firings must converge on exactly one valid settled receipt with no
# temp leftovers — last-writer-wins is acceptable, a corrupt or partial file is not.

echo ""
echo "=== receipt shape, atomicity and idempotency ==="

# --- E4: receipt entry carries the required keys ---
E4_SID="e4shape"
E4_FP="$(node_path "$REPO/docs/not-a-rule.md")"
fire "$E4_SID" "$E4_FP" '"path_glob_match"' >/dev/null
E4_KEYS="$(node -e "
const fs=require('fs'),path=require('path');
const dir=path.join(process.argv[1], process.argv[2] + '.instructions-loaded');
const f=fs.readdirSync(dir).filter(n=>n.endsWith('.json'))[0];
const j=JSON.parse(fs.readFileSync(path.join(dir,f),'utf8'));
const need=['fired_at','file_path','load_reason','verdict','payload_keys'];
const miss=need.filter(k=>!(k in j));
console.log(miss.length===0 && Array.isArray(j.payload_keys) ? 'ok' : 'missing:'+miss.join(',')+' payload_keys_array='+Array.isArray(j.payload_keys));
" "$(node_path "$WFDIR")" "$E4_SID" 2>&1)"
[ "$E4_KEYS" = "ok" ] && pass "E4: receipt entry carries fired_at/file_path/load_reason/verdict/payload_keys" \
    || fail "E4: receipt entry shape wrong ($E4_KEYS)"

# --- E5: 20 concurrent invocations against one session_id lose zero entries.
# Distinct file paths -> distinct keys: this covers directory-level races only. ---
E5_SID="e5concurrent"
for i in $(seq 1 20); do
    printf 'concurrent probe %s\n' "$i" > "$REPO/rules/conc-$i.md"
done
for i in $(seq 1 20); do
    fire "$E5_SID" "$(node_path "$REPO/rules/conc-$i.md")" OMIT >/dev/null &
done
wait
e5_count="$(find "$WFDIR/$E5_SID.instructions-loaded" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
e5_partial="$(find "$WFDIR/$E5_SID.instructions-loaded" -type f ! -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$e5_count" = "20" ] && [ "$e5_partial" = "0" ]; then
    pass "E5: 20 concurrent firings produced 20 receipts and no leftover temp files"
else
    fail "E5: want 20 receipts / 0 temp leftovers, got $e5_count receipts / $e5_partial leftovers"
fi

# --- I1 (C10): the SAME session + SAME file fired 10 times SEQUENTIALLY.
# Every firing targets one key, so the directory must still hold exactly one entry. ---
I_SID="idemseq"
printf '# repeated probe\n' > "$REPO/rules/idem.md"
I_FP="$(node_path "$REPO/rules/idem.md")"
for _ in $(seq 1 10); do fire "$I_SID" "$I_FP" OMIT >/dev/null; done
i1_count="$(find "$WFDIR/$I_SID.instructions-loaded" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
i1_all="$(find "$WFDIR/$I_SID.instructions-loaded" -type f 2>/dev/null | wc -l | tr -d ' ')"
i1_verdict="$(read_field "$I_SID" "$I_FP" verdict)"
if [ "$i1_count" = "1" ] && [ "$i1_all" = "1" ] && [ "$i1_verdict" = "S-MISSING" ]; then
    pass "I1: 10 sequential firings of one key settle to exactly one valid receipt"
else
    fail "I1: want 1 json / 1 total file / verdict S-MISSING, got $i1_count / $i1_all / $i1_verdict"
fi

# --- I2 (C10): the SAME session + SAME file fired 20 times CONCURRENTLY.
# This is the case the distinct-path concurrency test cannot reach: N writers
# racing on ONE destination. Exactly one settled, parseable receipt must remain. ---
I2_SID="idempar"
printf '# racing probe\n' > "$REPO/rules/idem2.md"
I2_FP="$(node_path "$REPO/rules/idem2.md")"
for _ in $(seq 1 20); do fire "$I2_SID" "$I2_FP" OMIT >/dev/null & done
wait
i2_count="$(find "$WFDIR/$I2_SID.instructions-loaded" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
i2_tmp="$(find "$WFDIR/$I2_SID.instructions-loaded" -type f ! -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
i2_parse="$(node -e "
const fs=require('fs'),path=require('path');
const dir=path.join(process.argv[1], process.argv[2] + '.instructions-loaded');
let bad=0, n=0;
for (const f of fs.readdirSync(dir)) {
  n++;
  try { const j=JSON.parse(fs.readFileSync(path.join(dir,f),'utf8'));
        if (!j.verdict || !j.file_path) bad++; }
  catch (_) { bad++; }
}
console.log(n + ':' + bad);
" "$(node_path "$WFDIR")" "$I2_SID" 2>&1)"
if [ "$i2_count" = "1" ] && [ "$i2_tmp" = "0" ] && [ "$i2_parse" = "1:0" ]; then
    pass "I2: 20 concurrent firings of ONE key leave exactly one parseable receipt"
else
    fail "I2: want 1 json / 0 temp / parse 1:0, got $i2_count / $i2_tmp / $i2_parse"
fi

# --- I3 (C9): repeated firings of the same finding must not multiply downstream.
# The supervisor is the consumer; a per-firing emit would flood it.

# This case MUST run under a RESOLVABLE workflow session. Everywhere else in this file
# WORKFLOW_PLANS_DIR is an empty fixture, so resolveWorkflowSessionId() returns null and
# the emit is skipped by design (E7) — counting findings there yields zero no matter
# what the hook does, and "zero findings" would be indistinguishable from perfect
# dedup. So I3 gets its own CWD carrying a WORKTREE_NOTES.md Session-ID (priority 1 of
# the resolution chain) and its own plans dir, and the first thing it asserts is that
# the session actually resolved. ---
I3_SID="idemsuper"
I3_CWD="$BASE/i3-cwd"
I3_PLANS="$BASE/i3-plans"
I3_WSID="20260101-000000"
mkdir -p "$I3_CWD" "$I3_PLANS"
printf 'Session-ID: %s\n' "$I3_WSID" > "$I3_CWD/WORKTREE_NOTES.md"
printf '# intent\n' > "$I3_PLANS/$I3_WSID-intent.md"
printf '# repeated probe with a resolvable session\n' > "$REPO/rules/idem3.md"
I3_FP="$(node_path "$REPO/rules/idem3.md")"
I3_PAYLOAD="$(node -e 'console.log(JSON.stringify({session_id:process.argv[1],file_path:process.argv[2],hook_event_name:"InstructionsLoaded"}))' "$I3_SID" "$I3_FP")"
for _ in $(seq 1 10); do
    printf '%s' "$I3_PAYLOAD" \
        | (cd "$I3_CWD" && WORKFLOW_PLANS_DIR="$(node_path "$I3_PLANS")" node "$(node_path "$HOOK")" >/dev/null 2>/dev/null) || true
done

I3_STATES="$(find "$I3_PLANS" -name '*-supervisor-state.json' 2>/dev/null | wc -l | tr -d ' ')"
I3_FINDINGS="$(node -e "
const fs=require('fs'),path=require('path');
let n=0;
for (const f of fs.readdirSync(process.argv[1])) {
  if (!f.endsWith('-supervisor-state.json')) continue;
  try {
    const j=JSON.parse(fs.readFileSync(path.join(process.argv[1],f),'utf8'));
    // the writer nests findings under layer1/alert/audit; older shapes wrap them in
    // a 'state' envelope. Count matches wherever they live so the assertion measures
    // the number of findings, never the shape of the file.
    const root=(j && j.state && typeof j.state === 'object') ? j.state : j;
    for (const g of ['layer1','alert','audit']) {
      const fx=((root||{})[g]||{}).findings||[];
      for (const x of fx) {
        if (!JSON.stringify(x).includes('idem3.md')) continue;
        // the state writer collapses an identical finding class into ONE record and
        // records how many times it was submitted. Count submissions, not records:
        // otherwise a hook that emits on every firing hides behind the writer's dedup.
        const c = Number(x.class_dedup_count);
        n += Number.isFinite(c) && c > 0 ? c : 1;
      }
    }
  } catch (_) {}
}
console.log(String(n));
" "$(node_path "$I3_PLANS")" 2>/dev/null || echo "ERR")"

if [ "$I3_STATES" = "0" ]; then
    fail "I3: no supervisor state file under the resolvable-session fixture — the workflow session never resolved, so a findings count here proves nothing about dedup"
elif [ "$I3_FINDINGS" = "0" ]; then
    fail "I3: the session resolved (states=$I3_STATES) but rules/idem3.md produced no finding at all — the S-MISSING verdict never reached the supervisor"
elif [ "$I3_FINDINGS" = "1" ]; then
    pass "I3: under a resolvable session, 10 repeated firings produced exactly one downstream finding"
else
    fail "I3: repeated firings multiplied downstream findings — $I3_FINDINGS findings for rules/idem3.md (want exactly 1)"
fi

# --- E6: no session_id anywhere -> unknown.instructions-loaded/ ---
E6_FP="$(node_path "$REPO/rules/missing.md")"
E6_RC=0
printf '%s' "$(node -e 'console.log(JSON.stringify({file_path:process.argv[1],hook_event_name:"InstructionsLoaded"}))' "$E6_FP")" \
    | (cd "$BASE" && node "$(node_path "$HOOK")" >/dev/null 2>/dev/null) || E6_RC=$?
E6_KEY="$(sha1_of "$E6_FP")"
if [ "$E6_RC" = "0" ] && [ -f "$WFDIR/unknown.instructions-loaded/$E6_KEY.json" ]; then
    pass "E6: missing session_id (payload and env) lands under unknown.instructions-loaded/"
else
    fail "E6: want a receipt at unknown.instructions-loaded/$E6_KEY.json (hook rc=$E6_RC)"
fi

# --- E6b (#2270): payload carries no session_id, but the env does. A hook invoked
# by a non-native-LLM harness gets its identity only from CLAUDE_CODE_SESSION_ID,
# so the receipt must be attributed to that session instead of landing in the
# shared unknown/ bucket where no session can ever read its own audit trail. ---
E6B_SID="e6bccsid"
E6B_FP="$(node_path "$REPO/rules/ok-listed.md")"
E6B_RC=0
printf '%s' "$(node -e 'console.log(JSON.stringify({file_path:process.argv[1],hook_event_name:"InstructionsLoaded"}))' "$E6B_FP")" \
    | (cd "$BASE" && CLAUDE_CODE_SESSION_ID="$E6B_SID" node "$(node_path "$HOOK")" >/dev/null 2>/dev/null) || E6B_RC=$?
E6B_KEY="$(sha1_of "$E6B_FP")"
if [ "$E6B_RC" = "0" ] && [ -f "$WFDIR/$E6B_SID.instructions-loaded/$E6B_KEY.json" ]; then
    pass "E6b: session_id absent from payload -> CLAUDE_CODE_SESSION_ID attributes the receipt"
else
    fail "E6b: want a receipt at $E6B_SID.instructions-loaded/$E6B_KEY.json (hook rc=$E6B_RC)"
fi

# --- E6c: both env vars set to different ids. The attribution order must be the
# SSOT resolver's (CLAUDE_CODE_SESSION_ID first), or a receipt is filed under an
# identity the session does not answer to. ---
E6C_CC="e6cccsid"
E6C_LEGACY="e6clegacysid"
E6C_FP="$(node_path "$REPO/rules/ok-conditional.md")"
E6C_RC=0
printf '%s' "$(node -e 'console.log(JSON.stringify({file_path:process.argv[1],hook_event_name:"InstructionsLoaded"}))' "$E6C_FP")" \
    | (cd "$BASE" && CLAUDE_SESSION_ID="$E6C_LEGACY" CLAUDE_CODE_SESSION_ID="$E6C_CC" node "$(node_path "$HOOK")" >/dev/null 2>/dev/null) || E6C_RC=$?
E6C_KEY="$(sha1_of "$E6C_FP")"
if [ "$E6C_RC" = "0" ] && [ -f "$WFDIR/$E6C_CC.instructions-loaded/$E6C_KEY.json" ] \
   && [ ! -f "$WFDIR/$E6C_LEGACY.instructions-loaded/$E6C_KEY.json" ]; then
    pass "E6c: both env ids present -> CLAUDE_CODE_SESSION_ID wins the attribution"
else
    fail "E6c: want the receipt under $E6C_CC only (hook rc=$E6C_RC)"
fi

# --- E6d: an explicit payload session_id outranks BOTH env vars — the env is a
# fallback for callers that supply nothing, never an override of the event. ---
E6D_SID="e6dpayloadsid"
E6D_FP="$(node_path "$REPO/docs/not-a-rule.md")"
E6D_RC=0
printf '%s' "$(node -e 'console.log(JSON.stringify({session_id:process.argv[1],file_path:process.argv[2],hook_event_name:"InstructionsLoaded"}))' "$E6D_SID" "$E6D_FP")" \
    | (cd "$BASE" && CLAUDE_CODE_SESSION_ID="e6dccsid" node "$(node_path "$HOOK")" >/dev/null 2>/dev/null) || E6D_RC=$?
E6D_KEY="$(sha1_of "$E6D_FP")"
if [ "$E6D_RC" = "0" ] && [ -f "$WFDIR/$E6D_SID.instructions-loaded/$E6D_KEY.json" ] \
   && [ ! -f "$WFDIR/e6dccsid.instructions-loaded/$E6D_KEY.json" ]; then
    pass "E6d: payload session_id outranks the CLAUDE_CODE_SESSION_ID fallback"
else
    fail "E6d: want the receipt under $E6D_SID only (hook rc=$E6D_RC)"
fi

# --- E7: wsid null skips ONLY the supervisor emit; the receipt still exists.
# WORKFLOW_PLANS_DIR is an empty fixture so resolveWorkflowSessionId() finds no
# plan artifact and returns null.
E7_SID="e7wsidnull"
E7_FP="$(node_path "$REPO/rules/missing.md")"
fire "$E7_SID" "$E7_FP" OMIT >/dev/null
e7_verdict="$(read_field "$E7_SID" "$E7_FP" verdict)"
e7_states="$(find "$PLANS" -name '*-supervisor-state.json' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$e7_verdict" = "S-MISSING" ] && [ "$e7_states" = "0" ]; then
    pass "E7: wsid null -> receipt written, supervisor emit skipped"
else
    fail "E7: want receipt verdict S-MISSING and 0 supervisor state files, got $e7_verdict / $e7_states"
fi

# --- E8: fail-open — malformed JSON, empty stdin, unresolvable receipt dir ---
BLOCKER="$BASE/blocker"; printf 'not a directory\n' > "$BLOCKER"
run_failopen() {
    local label="$1" input="$2" wfdir="$3" rc=0 out
    out="$(printf '%s' "$input" | (cd "$BASE" && CLAUDE_WORKFLOW_DIR="$wfdir" node "$(node_path "$HOOK")" 2>/dev/null))" || rc=$?
    if [ "$rc" != "0" ]; then
        fail "$label: want exit 0 (fail-open), got $rc"
    elif [ -n "$out" ]; then
        fail "$label: stdout must be empty, got '$out'"
    else
        pass "$label"
    fi
}
run_failopen "E8a: malformed JSON on stdin exits 0 with empty stdout" '{"file_path": ' "$(node_path "$WFDIR")"
run_failopen "E8b: empty stdin exits 0 with empty stdout" '' "$(node_path "$WFDIR")"
run_failopen "E8c: unresolvable receipt dir exits 0 with empty stdout" \
    "{\"session_id\":\"e8c\",\"file_path\":\"$E7_FP\"}" "$(node_path "$BLOCKER")/nested"
