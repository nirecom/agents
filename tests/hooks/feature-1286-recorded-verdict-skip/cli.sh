#!/bin/bash
# shellcheck shell=bash
# feature-1286 CLI cases: bin/workflow/record-skip-judgment.
# Relies on helpers.sh being sourced by the dispatcher.

echo ""
echo "=== RV-6 / RV-18: bin/workflow/record-skip-judgment CLI ==="

if [ ! -f "$RECORD_CLI" ]; then
  # Red-phase: CLI not yet implemented.
  fail "RV-6a: valid outline → RECORDED=outline (CLI not yet implemented)"
  fail "RV-6a: valid outline → exit 0 (CLI not yet implemented)"
  fail "RV-6b: invalid --target exits non-zero (CLI not yet implemented)"
  fail "RV-6c: detail without --c3 exits non-zero (CLI not yet implemented)"
  fail "RV-18a: valid detail → RECORDED=detail (CLI not yet implemented)"
  fail "RV-18b: valid detail → all_conditions_met=true (CLI not yet implemented)"
  fail "RV-18c: valid detail → exit 0 (CLI not yet implemented)"
else
  # RV-6a: valid outline args → exit 0 + RECORDED=outline in stdout.
  RV6A_RC=0
  RV6A_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" run_with_timeout node "$RECORD_CLI_N" \
    --session rv6a --target outline --c1 --c2 2>&1)" || RV6A_RC=$?
  check_contains "RV-6a: valid outline → stdout contains RECORDED=outline" "RECORDED=outline" "$RV6A_OUT"
  if [ "$RV6A_RC" -eq 0 ]; then pass "RV-6a: valid outline → exit 0"
  else fail "RV-6a: valid outline → expected exit 0, got $RV6A_RC"; fi

  # RV-6b: invalid --target → exit non-zero.
  RC=0
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" run_with_timeout node "$RECORD_CLI_N" \
    --session rv6b --target badvalue --c1 --c2 >/dev/null 2>&1 || RC=$?
  if [ "$RC" -ne 0 ]; then pass "RV-6b: invalid --target exits non-zero"
  else fail "RV-6b: invalid --target should exit non-zero, got exit 0"; fi

  # RV-6c: detail missing --c3 → exit non-zero.
  RC=0
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" run_with_timeout node "$RECORD_CLI_N" \
    --session rv6c --target detail --c1 --c2 >/dev/null 2>&1 || RC=$?
  if [ "$RC" -ne 0 ]; then pass "RV-6c: detail without --c3 exits non-zero"
  else fail "RV-6c: detail without --c3 should exit non-zero, got exit 0"; fi

  # RV-18: valid detail args → exit 0 + RECORDED=detail + all_conditions_met=true.
  RV18_RC=0
  RV18_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" run_with_timeout node "$RECORD_CLI_N" \
    --session rv18 --target detail --c1 true --c2 true --c3 true 2>&1)" || RV18_RC=$?
  check_contains "RV-18a: valid detail → stdout contains RECORDED=detail" "RECORDED=detail" "$RV18_OUT"
  check_contains "RV-18b: valid detail → stdout contains all_conditions_met=true" "all_conditions_met=true" "$RV18_OUT"
  if [ "$RV18_RC" -eq 0 ]; then pass "RV-18c: valid detail → exit 0"
  else fail "RV-18c: valid detail → expected exit 0, got $RV18_RC"; fi
fi

# ---------------------------------------------------------------------------
# RV-33: hardening #1 (plan RV-19) — write failure (CLAUDE_WORKFLOW_DIR points
# to a regular file) → CLI exits non-zero + stderr contains "write verification failed".
#
# Create a regular file at $TMPDIR_BASE/wfblock and set CLAUDE_WORKFLOW_DIR to
# that path. writeState → fs.mkdirSync(dir,{recursive:true}) fails deterministically
# (ENOTDIR) because the path is a file, not a directory.
# RED until hardening #1 adds post-write read-back verification with exit(1).
# ---------------------------------------------------------------------------
echo ""
echo "=== RV-33: hardening #1 — CLI write failure → exit non-zero + 'write verification failed' ==="
if [ ! -f "$RECORD_CLI" ]; then
  fail "RV-33a: CLI not implemented (file missing)"
  fail "RV-33b: CLI not implemented (file missing)"
else
  RV33_BLOCK="$TMPDIR_BASE/wfblock"
  touch "$RV33_BLOCK"
  RV33_BLOCK_N="$(cygpath -m "$RV33_BLOCK" 2>/dev/null || echo "$RV33_BLOCK")"
  RV33_RC=0
  RV33_OUT="$(CLAUDE_WORKFLOW_DIR="$RV33_BLOCK_N" run_with_timeout node "$RECORD_CLI_N" \
    --session rv33 --target outline --c1 --c2 2>&1)" || RV33_RC=$?
  if [ "$RV33_RC" -ne 0 ]; then pass "RV-33a: write failure → exit non-zero"
  else fail "RV-33a: expected exit non-zero on write failure, got exit 0"; fi
  check_contains "RV-33b: stderr contains 'write verification failed'" "write verification failed" "$RV33_OUT"
fi

# ---------------------------------------------------------------------------
# RV-34: hardening #1 (plan RV-20) — stale record regression: CLI must NOT
# report success when a write fails but an older record already exists.
#
# Steps:
#   1. Write a valid old record for rv34 in the normal $WORKFLOW_DIR.
#   2. Repoint CLAUDE_WORKFLOW_DIR to the blocking file (write now fails).
#   3. Run CLI for rv34 with new/different values.
#   4. Assert exit != 0 (must not falsely succeed using the stale record).
#   5. Assert no "RECORDED=outline" in stdout (must not claim success).
# RED until hardening #1 performs read-back matching against the CURRENT write.
# ---------------------------------------------------------------------------
echo ""
echo "=== RV-34: hardening #1 — stale record must not be reported as success ==="
if [ ! -f "$RECORD_CLI" ]; then
  fail "RV-34a: CLI not implemented (file missing)"
  fail "RV-34b: CLI not implemented (file missing)"
else
  # Step 1: write a valid old record for rv34 in the normal WORKFLOW_DIR.
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" run_with_timeout node "$RECORD_CLI_N" \
    --session rv34 --target outline --c1 --c2 >/dev/null 2>&1 || true
  # Step 2: repoint to the blocking file.
  RV34_BLOCK_N="$(cygpath -m "$TMPDIR_BASE/wfblock" 2>/dev/null || echo "$TMPDIR_BASE/wfblock")"
  # Step 3: run CLI with new values (c2=false would yield all_conditions_met=false — different from old record).
  RV34_RC=0
  RV34_OUT="$(CLAUDE_WORKFLOW_DIR="$RV34_BLOCK_N" run_with_timeout node "$RECORD_CLI_N" \
    --session rv34 --target outline --c1 true --c2 false 2>&1)" || RV34_RC=$?
  # Step 4: must exit non-zero.
  if [ "$RV34_RC" -ne 0 ]; then pass "RV-34a: stale record → exit non-zero (no false success)"
  else fail "RV-34a: expected exit non-zero for stale record, got exit 0"; fi
  # Step 5: must not claim RECORDED=outline success.
  check_not_contains "RV-34b: stale record → no RECORDED=outline in stdout" "RECORDED=outline" "$RV34_OUT"
fi
