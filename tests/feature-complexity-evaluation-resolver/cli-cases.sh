# tests/feature-complexity-evaluation-resolver/cli-cases.sh
# Tests: bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation
# Tags: L2, workflow, complexity-evaluation, cli, scope:issue-specific
#
# Sourced by feature-complexity-evaluation-resolver.sh after api-cases.sh (lib.sh
# owns every helper); cases run at source time, ungated — a required CLI's
# absence FAILS at CE-REQ-2 in lib.sh, never skips. Covers CE-10..CE-12,
# CE-CLI-FAIL-1..5, CE-SEC-1..7, CE-READ-SEC-1..4, CE-CLI-IDEMP-1.
echo ""
echo "=== CE-10..CE-12: record/read CLIs ==="
# CE-10: CLI record + CLI read round-trip (escalating signals present).
SID="ce10-$$"
CE10_RC=0
CE10_REC="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
  --session "$SID" --signals "S1-multi-file,S2-architecture" 2>/dev/null)" || CE10_RC=$?
assert_eq "CE-10a. record CLI exit 0" '0' "$CE10_RC"
check_contains "CE-10b. record CLI stdout carries the RECORDED_COMPLEXITY receipt" "RECORDED_COMPLEXITY" "$CE10_REC"
check_not_contains "CE-10b2. receipt no longer echoes a caller verdict" "verdict=" "$CE10_REC"
# state file created under CLAUDE_WORKFLOW_DIR
if [ -f "$WORKFLOW_DIR/${SID}.json" ]; then
  pass "CE-10c. state file created under CLAUDE_WORKFLOW_DIR"
else
  fail "CE-10c. state file NOT created under CLAUDE_WORKFLOW_DIR"
fi
CE10R_RC=0
CE10_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$READ_CLI_N" --session "$SID" 2>/dev/null)" || CE10R_RC=$?
assert_eq "CE-10d. read CLI exit 0" '0' "$CE10R_RC"
check_contains "CE-10e. CLI read reports level high" "level=high" "$CE10_OUT"
check_contains "CE-10f. CLI read reports signal S1-multi-file" "S1-multi-file" "$CE10_OUT"

# CE-11: CLI read with no state → NONE (exit 0, not a crash).
SID="ce11-missing-$$"
CE11_RC=0
CE11_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$READ_CLI_N" --session "$SID" 2>/dev/null)" || CE11_RC=$?
assert_eq "CE-11a. read CLI (no state) exit 0" '0' "$CE11_RC"
check_contains "CE-11b. CLI read (no state) prints NONE" "NONE" "$CE11_OUT"

# CE-12: CLI read-back hardening — record then read, level matches exactly.
SID="ce12-$$"
CE12_RC=0
CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
  --session "$SID" --signals "" >/dev/null 2>&1 || CE12_RC=$?
assert_eq "CE-12a. record CLI (empty signals) exit 0" '0' "$CE12_RC"
CE12_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$READ_CLI_N" --session "$SID" 2>/dev/null)"
check_contains "CE-12b. CLI read-back level=low" "level=low" "$CE12_OUT"

# ------------------------------------------------------------------
# C2 — CLI usage failures (bad args must exit non-zero). Since #2099 the
# level is derived, so --verdict in any form is a usage error.
# ------------------------------------------------------------------
echo ""
echo "=== CE-CLI-FAIL: invalid CLI args → exit 1 ==="
CEF1_RC=0
CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
  --session "cef1-$$" --signals "" --verdict high >/dev/null 2>&1 || CEF1_RC=$?
assert_eq "CE-CLI-FAIL-1. retired --verdict flag → exit 1" '1' "$CEF1_RC"

CEF2_RC=0
CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
  --session "" --signals "" >/dev/null 2>&1 || CEF2_RC=$?
assert_eq "CE-CLI-FAIL-2. empty session id → exit 1" '1' "$CEF2_RC"

CEF3_RC=0
CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
  --signals "" >/dev/null 2>&1 || CEF3_RC=$?
assert_eq "CE-CLI-FAIL-3. missing --session → exit 1" '1' "$CEF3_RC"

CEF4_RC=0
CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
  --session "cef4-$$" >/dev/null 2>&1 || CEF4_RC=$?
assert_eq "CE-CLI-FAIL-4. missing --signals → exit 1" '1' "$CEF4_RC"

CEF5_RC=0
CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
  --session "cef5-$$" --verdict sonnet >/dev/null 2>&1 || CEF5_RC=$?
assert_eq "CE-CLI-FAIL-5. old --verdict value with no --signals → exit 1" '1' "$CEF5_RC"

# ------------------------------------------------------------------
# C3 — security / injection on --session (must reject, no stray file)
# sessionId contract: /^[A-Za-z0-9_-]+$/
# ------------------------------------------------------------------
echo ""
echo "=== CE-SEC: malicious --session values rejected ==="
# Pre-seed a canary file outside the reject set to prove no traversal write.
CANARY="$TMPDIR_BASE/canary-evil"
printf 'ORIGINAL' > "$CANARY"

sec_reject() {
  local desc="$1" sid="$2"
  local rc=0
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
    --session "$sid" --signals "S1" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "$desc (exit $rc)"
  else
    fail "$desc -- expected non-zero exit, got 0"
  fi
}
sec_reject "CE-SEC-1. path traversal ../evil rejected"       "../evil"
sec_reject "CE-SEC-2. path separator foo/bar rejected"        "foo/bar"
sec_reject "CE-SEC-3. shell metachar foo;bar rejected"        "foo;bar"
sec_reject "CE-SEC-4. empty string rejected"                  ""
LONGID="$(printf 'a%.0s' $(seq 1 200))/x"
sec_reject "CE-SEC-5. long id with separator rejected"        "$LONGID"

# Traversal target must not have been created/overwritten.
if [ "$(cat "$CANARY" 2>/dev/null)" = "ORIGINAL" ]; then
  pass "CE-SEC-6. canary file untouched by traversal attempts"
else
  fail "CE-SEC-6. canary file was modified — traversal not contained"
fi
# And no file materialized above the workflow dir via ../evil.
if [ -f "$WORKFLOW_DIR/../evil.json" ]; then
  fail "CE-SEC-7. ../evil.json created outside workflow dir"
  rm -f "$WORKFLOW_DIR/../evil.json"
else
  pass "CE-SEC-7. no ../evil.json created outside workflow dir"
fi

# ------------------------------------------------------------------
# C4 — read CLI: malicious --session values also rejected (CPR-ORTH)
# ------------------------------------------------------------------
echo ""
echo "=== CE-READ-SEC: read CLI rejects malicious --session ==="
sec_reject_read() {
  local desc="$1" sid="$2"
  local rc=0
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$READ_CLI_N" \
    --session "$sid" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "$desc (exit $rc)"
  else
    fail "$desc -- expected non-zero exit, got 0"
  fi
}
sec_reject_read "CE-READ-SEC-1. path traversal ../evil rejected"   "../evil"
sec_reject_read "CE-READ-SEC-2. path separator foo/bar rejected"    "foo/bar"
sec_reject_read "CE-READ-SEC-3. shell metachar foo;bar rejected"    "foo;bar"
sec_reject_read "CE-READ-SEC-4. empty string rejected"              ""

# ------------------------------------------------------------------
# C9 — CLI-level idempotency (double record, same signals)
# ------------------------------------------------------------------
echo ""
echo "=== CE-CLI-IDEMP: double CLI record, same signals ==="
SID="ceidemp-$$"
I1_RC=0; I2_RC=0
CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
  --session "$SID" --signals "S3-security" >/dev/null 2>&1 || I1_RC=$?
CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$RECORD_CLI_N" \
  --session "$SID" --signals "S3-security" >/dev/null 2>&1 || I2_RC=$?
assert_eq "CE-CLI-IDEMP-1a. first record exit 0" '0' "$I1_RC"
assert_eq "CE-CLI-IDEMP-1b. second record exit 0 (idempotent)" '0' "$I2_RC"
IDEMP_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node "$READ_CLI_N" --session "$SID" 2>/dev/null)"
check_contains "CE-CLI-IDEMP-1c. read still level=high" "level=high" "$IDEMP_OUT"
# Exactly one state file (no duplication).
N_FILES="$(ls -1 "$WORKFLOW_DIR/${SID}.json" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "CE-CLI-IDEMP-1d. exactly one state file" '1' "$N_FILES"
