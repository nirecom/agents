# L2 INTEGRATION — not-needed-handlers.js (HANDLER_READY guarded)
# Sourced by feature-speculative-skip-complete.sh.

echo ""
echo "=== L2 INTEGRATION: not-needed-handlers.js ==="

# Invoke a handler directly via the exported handle(ctx). This mirrors the
# hook's dispatch: ctx carries cmd + sessionId + pushMessage/signalFatal stubs.
run_handler() {
  local sid="$1" cmd="$2"
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const h=require('$HANDLERS_N');
    const ctx={ cmd: process.argv[1], sessionId: process.argv[2],
      pushMessage: ()=>{}, signalFatal: ()=>{} };
    h.handle(ctx);
  " "$cmd" "$sid" 2>/dev/null
}

if [ "$HANDLER_READY" = "true" ]; then
  # H1: OUTLINE_NOT_NEEDED → outline has skip_reason AND skip_verdict.verdict==='pending'
  SID="h1-$$"
  run_handler "$SID" 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: not needed here>>"'
  H1_OUT="$(node_call "
    const io=require('$BARREL_N');
    const s=io.readState('$SID');
    const st=(s&&s.steps&&s.steps.outline)||{};
    const ok=(typeof st.skip_reason==='string'&&st.skip_reason.length>0)&&(st.skip_verdict&&st.skip_verdict.verdict==='pending');
    console.log(ok?'OK':'BAD:'+JSON.stringify(st));
  ")"
  assert_eq "H1. OUTLINE handler sets skip_reason + skip_verdict pending" 'OK' "$H1_OUT"

  # H2: DETAIL_NOT_NEEDED → same
  SID="h2-$$"
  run_handler "$SID" 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: not needed here>>"'
  H2_OUT="$(node_call "
    const io=require('$BARREL_N');
    const s=io.readState('$SID');
    const st=(s&&s.steps&&s.steps.detail)||{};
    const ok=(typeof st.skip_reason==='string'&&st.skip_reason.length>0)&&(st.skip_verdict&&st.skip_verdict.verdict==='pending');
    console.log(ok?'OK':'BAD:'+JSON.stringify(st));
  ")"
  assert_eq "H2. DETAIL handler sets skip_reason + skip_verdict pending" 'OK' "$H2_OUT"

  # H3: C2 fix — skip_reason preserved (not erased by recordSkipVerdict inside handler)
  SID="h3-$$"
  run_handler "$SID" 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: preserve me exactly>>"'
  H3_OUT="$(node_call "
    const io=require('$BARREL_N');
    const s=io.readState('$SID');
    console.log((s&&s.steps&&s.steps.outline&&s.steps.outline.skip_reason)||'MISSING');
  ")"
  assert_eq "H3. skip_reason preserved through handler (C2)" 'preserve me exactly' "$H3_OUT"
else
  skip "H1..H3 (HANDLER not ready)"
  skip "H1..H3 (HANDLER not ready)"
  skip "H1..H3 (HANDLER not ready)"
fi
