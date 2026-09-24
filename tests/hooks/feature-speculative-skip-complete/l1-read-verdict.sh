# L1 UNIT — readSkipVerdict / hasSpeculativeSkipPending (API_READY guarded)
# Sourced by feature-speculative-skip-complete.sh.

echo ""
echo "=== L1 UNIT: readSkipVerdict / hasSpeculativeSkipPending ==="

if [ "$API_READY" = "true" ]; then
  # U7: legacy skip (no skip_verdict field) → readSkipVerdict null (C4 fail-open)
  SID="u7-$$"
  U7_OUT="$(node_call "
    const io=require('$BARREL_N');
    io.markStep('$SID','outline','skipped',{skip_reason:'legacy'});
    const v=io.readSkipVerdict('$SID','outline');
    console.log(v===null?'null':JSON.stringify(v));
  ")"
  assert_eq "U7. legacy skip (no skip_verdict) → null" 'null' "$U7_OUT"

  # U8: skip_verdict present → returns the object
  SID="u8-$$"
  U8_OUT="$(node_call "
    const io=require('$BARREL_N');
    io.recordSkipVerdict('$SID','outline','confirm','test');
    const v=io.readSkipVerdict('$SID','outline');
    console.log((v && v.verdict==='confirm' && v.source==='test')?'OK':'BAD:'+JSON.stringify(v));
  ")"
  assert_eq "U8. skip_verdict present → returned object" 'OK' "$U8_OUT"

  # U9: state file missing/corrupt → null
  SID="u9-missing-$$"
  U9_OUT="$(node_call "
    const io=require('$BARREL_N');
    const v=io.readSkipVerdict('$SID','outline');
    console.log(v===null?'null':JSON.stringify(v));
  ")"
  assert_eq "U9. missing state → null" 'null' "$U9_OUT"

  # U10: hasSpeculativeSkipPending true when verdict === pending
  SID="u10-$$"
  U10_OUT="$(node_call "
    const io=require('$BARREL_N');
    io.recordSkipVerdict('$SID','outline','pending','sentinel');
    console.log(io.hasSpeculativeSkipPending('$SID','outline')===true?'true':'false');
  ")"
  assert_eq "U10. hasSpeculativeSkipPending true for pending" 'true' "$U10_OUT"

  # U11: false when verdict is confirm
  SID="u11-$$"
  U11_OUT="$(node_call "
    const io=require('$BARREL_N');
    io.recordSkipVerdict('$SID','outline','confirm','test');
    console.log(io.hasSpeculativeSkipPending('$SID','outline')===false?'false':'true');
  ")"
  assert_eq "U11. hasSpeculativeSkipPending false for confirm" 'false' "$U11_OUT"

  # U12: false when no skip_verdict field (legacy)
  SID="u12-$$"
  U12_OUT="$(node_call "
    const io=require('$BARREL_N');
    io.markStep('$SID','outline','skipped',{skip_reason:'legacy'});
    console.log(io.hasSpeculativeSkipPending('$SID','outline')===false?'false':'true');
  ")"
  assert_eq "U12. hasSpeculativeSkipPending false for legacy skip" 'false' "$U12_OUT"
else
  skip "U7..U12 (API absent)"
  skip "U7..U12 (API absent)"
  skip "U7..U12 (API absent)"
  skip "U7..U12 (API absent)"
  skip "U7..U12 (API absent)"
  skip "U7..U12 (API absent)"
fi
