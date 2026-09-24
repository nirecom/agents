# L1 CLI — record-skip-verdict (CLI_READY guarded)
# Sourced by feature-speculative-skip-complete.sh.

echo ""
echo "=== L1 CLI: record-skip-verdict ==="

run_cli() {
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI" "$@" 2>&1
}

if [ "$CLI_READY" = "true" ]; then
  # C1: --verdict confirm --target outline → exit 0, RECORDED line
  SID="c1-$$"
  C1_OUT="$(run_cli --session "$SID" --target outline --verdict confirm)"; C1_RC=$?
  if [ "$C1_RC" = "0" ] && printf '%s' "$C1_OUT" | grep -q "RECORDED=outline verdict=confirm"; then
    pass "C1. confirm/outline → exit 0 + RECORDED line"
  else
    fail "C1. confirm/outline — rc=$C1_RC out=$C1_OUT"
  fi

  # C2: --verdict veto --target detail → exit 0, RECORDED line
  SID="c2-$$"
  C2_OUT="$(run_cli --session "$SID" --target detail --verdict veto)"; C2_RC=$?
  if [ "$C2_RC" = "0" ] && printf '%s' "$C2_OUT" | grep -q "RECORDED=detail verdict=veto"; then
    pass "C2. veto/detail → exit 0 + RECORDED line"
  else
    fail "C2. veto/detail — rc=$C2_RC out=$C2_OUT"
  fi

  # C3: --verdict pending → exit 1 (pending not accepted via CLI)
  SID="c3-$$"
  run_cli --session "$SID" --target outline --verdict pending >/dev/null 2>&1; C3_RC=$?
  assert_eq "C3. pending verdict via CLI → exit 1" '1' "$C3_RC"

  # C4: --verdict unknown → exit 1
  SID="c4-$$"
  run_cli --session "$SID" --target outline --verdict unknown >/dev/null 2>&1; C4_RC=$?
  assert_eq "C4. unknown verdict → exit 1" '1' "$C4_RC"

  # C5: missing --session → exit 1
  run_cli --target outline --verdict confirm >/dev/null 2>&1; C5_RC=$?
  assert_eq "C5. missing --session → exit 1" '1' "$C5_RC"

  # C6: missing --target → exit 1
  SID="c6-$$"
  run_cli --session "$SID" --verdict confirm >/dev/null 2>&1; C6_RC=$?
  assert_eq "C6. missing --target → exit 1" '1' "$C6_RC"

  # C7: --target invalid → exit 1
  SID="c7-$$"
  run_cli --session "$SID" --target bogus --verdict confirm >/dev/null 2>&1; C7_RC=$?
  assert_eq "C7. invalid --target → exit 1" '1' "$C7_RC"

  # C8: path-traversal --session → exit 1 (assertValidSessionId rejects)
  run_cli --session "../evil" --target outline --verdict confirm >/dev/null 2>&1; C8_RC=$?
  assert_eq "C8. path-traversal --session → exit 1" '1' "$C8_RC"

  # C9: shell-metachar --session → exit 1 (assertValidSessionId rejects)
  run_cli --session 'sid;rm' --target outline --verdict confirm >/dev/null 2>&1; C9_RC=$?
  assert_eq "C9. shell-metachar --session → exit 1" '1' "$C9_RC"
else
  skip "C1..C7 (CLI absent)"
  skip "C1..C7 (CLI absent)"
  skip "C1..C7 (CLI absent)"
  skip "C1..C7 (CLI absent)"
  skip "C1..C7 (CLI absent)"
  skip "C1..C7 (CLI absent)"
  skip "C1..C7 (CLI absent)"
fi
