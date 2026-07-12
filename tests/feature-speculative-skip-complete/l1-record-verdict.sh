# L1 UNIT — recordSkipVerdict (API_READY guarded)
# Sourced by feature-speculative-skip-complete.sh; inherits PASS/FAIL/SKIP,
# assert_eq, node_call, $BARREL_N, $API_READY.

echo ""
echo "=== L1 UNIT: recordSkipVerdict ==="

if [ "$API_READY" = "true" ]; then
  # U1: pending verdict stored (verdict, source, recorded_at present)
  SID="u1-$$"
  U1_OUT="$(node_call "
    const io=require('$BARREL_N');
    io.recordSkipVerdict('$SID','outline','pending','sentinel');
    const s=io.readState('$SID');
    const sv=s.steps.outline.skip_verdict||{};
    const ok = sv.verdict==='pending' && sv.source==='sentinel' && typeof sv.recorded_at==='string' && sv.recorded_at.length>0;
    console.log(ok?'OK':'BAD:'+JSON.stringify(sv));
  ")"
  assert_eq "U1. pending verdict stored (verdict/source/recorded_at)" 'OK' "$U1_OUT"

  # U2: confirm verdict stored
  SID="u2-$$"
  U2_OUT="$(node_call "
    const io=require('$BARREL_N');
    io.recordSkipVerdict('$SID','outline','confirm','skip-verifier');
    const s=io.readState('$SID');
    console.log(s.steps.outline.skip_verdict.verdict);
  ")"
  assert_eq "U2. confirm verdict stored" 'confirm' "$U2_OUT"

  # U3: veto verdict stored
  SID="u3-$$"
  U3_OUT="$(node_call "
    const io=require('$BARREL_N');
    io.recordSkipVerdict('$SID','detail','veto','skip-verifier');
    const s=io.readState('$SID');
    console.log(s.steps.detail.skip_verdict.verdict);
  ")"
  assert_eq "U3. veto verdict stored" 'veto' "$U3_OUT"

  # U4: C2 preservation — skip_reason survives a later recordSkipVerdict
  SID="u4-$$"
  U4_OUT="$(node_call "
    const io=require('$BARREL_N');
    io.markStep('$SID','outline','skipped',{skip_reason:'test'});
    io.recordSkipVerdict('$SID','outline','pending','sentinel');
    const s=io.readState('$SID');
    console.log(s.steps.outline.skip_reason);
  ")"
  assert_eq "U4. skip_reason preserved after recordSkipVerdict (C2)" 'test' "$U4_OUT"

  # U5: invalid verdict → silent return, existing state unchanged
  SID="u5-$$"
  U5_OUT="$(node_call "
    const io=require('$BARREL_N');
    io.markStep('$SID','outline','skipped',{skip_reason:'orig'});
    io.recordSkipVerdict('$SID','outline','unknown','sentinel');
    const s=io.readState('$SID');
    const noVerdict = (s.steps.outline.skip_verdict===undefined || s.steps.outline.skip_verdict===null);
    console.log((s.steps.outline.skip_reason==='orig' && noVerdict)?'UNCHANGED':'MUTATED:'+JSON.stringify(s.steps.outline));
  ")"
  assert_eq "U5. invalid verdict → silent, state unchanged" 'UNCHANGED' "$U5_OUT"

  # U6: no state file → recordSkipVerdict creates state gracefully (fail-open)
  SID="u6-$$"
  U6_OUT="$(node_call "
    const io=require('$BARREL_N');
    io.recordSkipVerdict('$SID','outline','pending','sentinel');
    const s=io.readState('$SID');
    console.log((s && s.steps && s.steps.outline && s.steps.outline.skip_verdict.verdict==='pending')?'CREATED':'MISSING');
  ")"
  assert_eq "U6. no prior state → created gracefully (fail-open)" 'CREATED' "$U6_OUT"
else
  skip "U1..U6 (API absent)"
  skip "U1..U6 (API absent)"
  skip "U1..U6 (API absent)"
  skip "U1..U6 (API absent)"
  skip "U1..U6 (API absent)"
  skip "U1..U6 (API absent)"
fi
