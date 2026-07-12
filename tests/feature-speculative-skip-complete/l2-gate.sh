# L2 INTEGRATION — next-step write_tests gate (GATE_READY guarded)
# Sourced by feature-speculative-skip-complete.sh.

echo ""
echo "=== L2 INTEGRATION: next-step write_tests gate ==="

run_next_step() {
  local sid="$1"
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" CLAUDE_PROJECT_DIR="$TMPDIR_BASE" \
    run_with_timeout node "$NEXT_STEP" --session "$sid" 2>&1
}

if [ "$GATE_READY" = "true" ]; then
  # G1: outline skipped + skip_verdict confirm → invoke, NEXT_SKILL=write-tests
  SID="g1-$$"
  write_gate_state "$SID" "outline" '{"status":"skipped","updated_at":"2026-04-11T10:00:00.000Z","skip_reason":"r","skip_verdict":{"verdict":"confirm","source":"skip-verifier","recorded_at":"2026-04-11T10:00:00.000Z"}}'
  G1_OUT="$(run_next_step "$SID")"
  if printf '%s' "$G1_OUT" | grep -q "ACTION=invoke" && printf '%s' "$G1_OUT" | grep -q "NEXT_SKILL=.*write-tests"; then
    pass "G1. confirm verdict → invoke write-tests"
  else
    fail "G1. confirm verdict — out=$G1_OUT"
  fi

  # G2: outline skipped + skip_verdict veto → blocked/abort mentioning RESET
  SID="g2-$$"
  write_gate_state "$SID" "outline" '{"status":"skipped","updated_at":"2026-04-11T10:00:00.000Z","skip_reason":"r","skip_verdict":{"verdict":"veto","source":"skip-verifier","recorded_at":"2026-04-11T10:00:00.000Z"}}'
  G2_OUT="$(run_next_step "$SID")"
  if printf '%s' "$G2_OUT" | grep -qiE "ACTION=(blocked|abort)" && printf '%s' "$G2_OUT" | grep -qi "RESET"; then
    pass "G2. veto verdict → blocked/abort mentioning RESET"
  else
    fail "G2. veto verdict — out=$G2_OUT"
  fi

  # G3: outline skipped + skip_verdict pending → blocked mentioning pending
  SID="g3-$$"
  write_gate_state "$SID" "outline" '{"status":"skipped","updated_at":"2026-04-11T10:00:00.000Z","skip_reason":"r","skip_verdict":{"verdict":"pending","source":"sentinel","recorded_at":"2026-04-11T10:00:00.000Z"}}'
  G3_OUT="$(run_next_step "$SID")"
  if printf '%s' "$G3_OUT" | grep -qiE "ACTION=(blocked|abort)" && printf '%s' "$G3_OUT" | grep -qi "pending"; then
    pass "G3. pending verdict → blocked mentioning pending"
  else
    fail "G3. pending verdict — out=$G3_OUT"
  fi

  # G4: outline skipped + NO skip_verdict field → fail-open, not blocked (legacy)
  SID="g4-$$"
  write_gate_state "$SID" "outline" '{"status":"skipped","updated_at":"2026-04-11T10:00:00.000Z","skip_reason":"legacy"}'
  G4_OUT="$(run_next_step "$SID")"
  if printf '%s' "$G4_OUT" | grep -q "ACTION=invoke"; then
    pass "G4. legacy skip (no verdict) → fail-open (not blocked)"
  else
    fail "G4. legacy skip — out=$G4_OUT"
  fi

  # G5: detail skipped + skip_verdict veto → blocked/abort
  SID="g5-$$"
  write_gate_state "$SID" "detail" '{"status":"skipped","updated_at":"2026-04-11T10:00:00.000Z","skip_reason":"r","skip_verdict":{"verdict":"veto","source":"skip-verifier","recorded_at":"2026-04-11T10:00:00.000Z"}}'
  G5_OUT="$(run_next_step "$SID")"
  if printf '%s' "$G5_OUT" | grep -qiE "ACTION=(blocked|abort)"; then
    pass "G5. detail veto verdict → blocked/abort"
  else
    fail "G5. detail veto — out=$G5_OUT"
  fi

  # G6: applyRecordedVerdictSkip path writes skip_verdict=pending (C4 gap)
  # When outline has valid skip_judgment, next-step's applyRecordedVerdictSkip must
  # also call recordSkipVerdict(pending) so the write_tests gate can detect A-4 skips.
  # hasValidSkipJudgment requires intent.md to exist (freshness check); we create a
  # dummy file and use a far-future recorded_at so the mtime check always passes.
  SID="g6-$$"
  G6_PLANS_DIR="$(mktemp -d)"
  printf '## Issues\n- #9999: g6 test issue\n' > "$G6_PLANS_DIR/${SID}-intent.md"
  write_gate_state "$SID" "outline" '{"status":"pending","updated_at":"2026-04-11T10:00:00.000Z","skip_judgment":{"judgment_source":"orchestrator","all_conditions_met":true,"conditions":{"so_c1":true,"so_c2":true},"recorded_at":"2099-01-01T00:00:00.000Z"}}'
  WORKFLOW_PLANS_DIR="$G6_PLANS_DIR" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" CLAUDE_PROJECT_DIR="$TMPDIR_BASE" \
    run_with_timeout node "$NEXT_STEP" --session "$SID" >/dev/null 2>&1 || true
  G6_SV="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const io = require('$STATEIO_N');
    const s = io.readState('$SID');
    const sv = s && s.steps && s.steps['outline'] && s.steps['outline'].skip_verdict;
    console.log(sv ? sv.verdict : 'none');
  " 2>&1)"
  assert_eq "G6. applyRecordedVerdictSkip writes skip_verdict=pending" "pending" "$G6_SV"
else
  skip "G1..G6 (GATE not ready)"
  skip "G1..G6 (GATE not ready)"
  skip "G1..G6 (GATE not ready)"
  skip "G1..G6 (GATE not ready)"
  skip "G1..G6 (GATE not ready)"
  skip "G1..G6 (GATE not ready)"
fi
