#!/usr/bin/env bash
# L1 unit tests for ROUND_NUMBER counter management in
# skills/make-detail-plan/scripts/run-codex-review-loop.sh (and outline-plan variant).
# Counter is per-stage: <PLANS_DIR>/drafts/<session-id>-<format>-round-number.txt
set -uo pipefail

AGENTS_WORKTREE="$(cd "$(dirname "$0")/.." && pwd)"
DETAIL_WRAPPER="$AGENTS_WORKTREE/skills/make-detail-plan/scripts/run-codex-review-loop.sh"
OUTLINE_WRAPPER="$AGENTS_WORKTREE/skills/make-outline-plan/scripts/run-codex-review-loop.sh"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

if [[ ! -f "$DETAIL_WRAPPER" ]]; then
    echo "SKIP: $DETAIL_WRAPPER does not exist"
    exit 0
fi

# Probe whether the wrapper manages the ROUND_NUMBER counter.
# If not, skip the entire suite (the source has not been modified yet).
if ! grep -q -- "round-number\|--round " "$DETAIL_WRAPPER"; then
    echo "FAIL: $DETAIL_WRAPPER does not manage ROUND_NUMBER counter (implementation missing)"
    exit 1
fi

# Helper: make a stub run-codex-review-loop binary in AGENTS_CONFIG_DIR/bin that
# returns the requested exit code. We don't need to exercise the binary itself —
# only verify the wrapper's counter management.
setup_test_env() {
    local test_tmp="$1"
    local exit_code="$2"  # exit code the stub should return
    local agents_dir="$test_tmp/agents"
    mkdir -p "$agents_dir/bin"

    cat > "$agents_dir/bin/run-codex-review-loop" << EOF
#!/usr/bin/env bash
# Echo the args (for verification of --round value)
echo "ARGS: \$*" > "$test_tmp/run-loop-argv.txt"
exit $exit_code
EOF
    chmod +x "$agents_dir/bin/run-codex-review-loop"

    local plans_dir="$test_tmp/plans"
    mkdir -p "$plans_dir/drafts"
    echo "# Draft" > "$plans_dir/drafts/sid-detail-draft.md"
    echo "# Outline" > "$plans_dir/sid-outline.md"

    echo "$agents_dir|$plans_dir"
}

# Invoke the detail wrapper with the given env
invoke_detail() {
    local agents_dir="$1"
    local plans_dir="$2"
    local sid="$3"
    local extensions_used="$4"
    local rc=0
    AGENTS_CONFIG_DIR="$agents_dir" SESSION_ID="$sid" PLANS_DIR="$plans_dir" \
        EXTENSIONS_USED="$extensions_used" \
        run_with_timeout bash "$DETAIL_WRAPPER" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

counter_file() {
    local plans_dir="$1"
    local sid="$2"
    local fmt="$3"
    echo "$plans_dir/drafts/$sid-$fmt-round-number.txt"
}

# ---------------------------------------------------------------------------
# 1. First invocation: counter file absent → starts at 1
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  IFS='|' read -r MOCK PLANS <<< "$(setup_test_env "$TMP" 1)"
  rc=$(invoke_detail "$MOCK" "$PLANS" "sid1" "0")
  CFILE=$(counter_file "$PLANS" "sid1" "detail-plan")
  ARGS=$(cat "$TMP/run-loop-argv.txt" 2>/dev/null || echo "")
  if echo "$ARGS" | grep -q -- "--round 1"; then
    pass "1: first invocation passes --round 1"
  else
    fail "1: expected --round 1 in args. Got: $ARGS"
  fi
}

# ---------------------------------------------------------------------------
# 2. Second invocation: counter increments to 2
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  IFS='|' read -r MOCK PLANS <<< "$(setup_test_env "$TMP" 1)"
  invoke_detail "$MOCK" "$PLANS" "sid2" "0" >/dev/null
  rc=$(invoke_detail "$MOCK" "$PLANS" "sid2" "0")
  ARGS=$(cat "$TMP/run-loop-argv.txt" 2>/dev/null || echo "")
  if echo "$ARGS" | grep -q -- "--round 2"; then
    pass "2: second invocation passes --round 2"
  else
    fail "2: expected --round 2. Got: $ARGS"
  fi
}

# ---------------------------------------------------------------------------
# 3. Third invocation: counter increments to 3 (post-extend scenario)
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  IFS='|' read -r MOCK PLANS <<< "$(setup_test_env "$TMP" 1)"
  invoke_detail "$MOCK" "$PLANS" "sid3" "0" >/dev/null
  invoke_detail "$MOCK" "$PLANS" "sid3" "0" >/dev/null
  rc=$(invoke_detail "$MOCK" "$PLANS" "sid3" "1")  # post-extend → EXTENSIONS_USED=1
  ARGS=$(cat "$TMP/run-loop-argv.txt" 2>/dev/null || echo "")
  if echo "$ARGS" | grep -q -- "--round 3"; then
    pass "3: third invocation passes --round 3"
  else
    fail "3: expected --round 3. Got: $ARGS"
  fi
}

# ---------------------------------------------------------------------------
# 4. APPROVED (exit 0) deletes counter file
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  IFS='|' read -r MOCK PLANS <<< "$(setup_test_env "$TMP" 0)"
  invoke_detail "$MOCK" "$PLANS" "sid4" "0" >/dev/null
  CFILE=$(counter_file "$PLANS" "sid4" "detail-plan")
  if [[ ! -f "$CFILE" ]]; then
    pass "4: APPROVED (exit 0) deletes counter file"
  else
    fail "4: counter file still exists after APPROVED. Path: $CFILE, content: $(cat "$CFILE")"
  fi
}

# ---------------------------------------------------------------------------
# 5. ESCALATE (exit 2) deletes counter file
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  IFS='|' read -r MOCK PLANS <<< "$(setup_test_env "$TMP" 2)"
  invoke_detail "$MOCK" "$PLANS" "sid5" "0" >/dev/null
  CFILE=$(counter_file "$PLANS" "sid5" "detail-plan")
  if [[ ! -f "$CFILE" ]]; then
    pass "5: ESCALATE (exit 2) deletes counter file"
  else
    fail "5: counter file still exists after ESCALATE"
  fi
}

# ---------------------------------------------------------------------------
# 6. CONTINUE (exit 1) preserves counter file
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  IFS='|' read -r MOCK PLANS <<< "$(setup_test_env "$TMP" 1)"
  invoke_detail "$MOCK" "$PLANS" "sid6" "0" >/dev/null
  CFILE=$(counter_file "$PLANS" "sid6" "detail-plan")
  if [[ -f "$CFILE" ]] && [[ "$(cat "$CFILE" | tr -d '[:space:]')" == "1" ]]; then
    pass "6: CONTINUE (exit 1) preserves counter file at value 1"
  else
    fail "6: counter file missing or wrong value after CONTINUE. Path: $CFILE, content: $(cat "$CFILE" 2>/dev/null)"
  fi
}

# ---------------------------------------------------------------------------
# 7. Exit 3 (arg error) preserves counter file
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  IFS='|' read -r MOCK PLANS <<< "$(setup_test_env "$TMP" 3)"
  invoke_detail "$MOCK" "$PLANS" "sid7" "0" >/dev/null
  CFILE=$(counter_file "$PLANS" "sid7" "detail-plan")
  if [[ -f "$CFILE" ]]; then
    pass "7: exit 3 preserves counter file"
  else
    fail "7: counter file deleted after exit 3"
  fi
}

# ---------------------------------------------------------------------------
# 8. EXTENSIONS_USED is independent of ROUND_NUMBER
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  IFS='|' read -r MOCK PLANS <<< "$(setup_test_env "$TMP" 1)"
  # First call with EXTENSIONS_USED=0
  invoke_detail "$MOCK" "$PLANS" "sid8" "0" >/dev/null
  # Second call with EXTENSIONS_USED=1 — round should still be 2, not reset
  invoke_detail "$MOCK" "$PLANS" "sid8" "1" >/dev/null
  ARGS=$(cat "$TMP/run-loop-argv.txt" 2>/dev/null || echo "")
  if echo "$ARGS" | grep -q -- "--round 2"; then
    pass "8: EXTENSIONS_USED=1 does not reset ROUND_NUMBER (still 2)"
  else
    fail "8: expected --round 2 with EXTENSIONS_USED=1. Got: $ARGS"
  fi
}

# ---------------------------------------------------------------------------
# 9. Counter file path follows the convention
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  IFS='|' read -r MOCK PLANS <<< "$(setup_test_env "$TMP" 1)"
  invoke_detail "$MOCK" "$PLANS" "mysid" "0" >/dev/null
  EXPECTED="$PLANS/drafts/mysid-detail-plan-round-number.txt"
  if [[ -f "$EXPECTED" ]]; then
    pass "9: counter at <plans>/drafts/<sid>-detail-plan-round-number.txt"
  else
    fail "9: counter not at expected path: $EXPECTED. Listing: $(ls "$PLANS/drafts/" 2>/dev/null)"
  fi
}

# ---------------------------------------------------------------------------
# 9b. Same for outline-plan format
# ---------------------------------------------------------------------------
if [[ -f "$OUTLINE_WRAPPER" ]]; then
  {
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
    IFS='|' read -r MOCK PLANS <<< "$(setup_test_env "$TMP" 1)"
    # outline wrapper expects an outline draft file
    mkdir -p "$PLANS/drafts"
    echo "# Outline Draft" > "$PLANS/drafts/mysid-outline-draft.md"
    AGENTS_CONFIG_DIR="$MOCK" SESSION_ID="mysid" PLANS_DIR="$PLANS" \
      EXTENSIONS_USED="0" \
      run_with_timeout bash "$OUTLINE_WRAPPER" >/dev/null 2>&1 || true
    EXPECTED="$PLANS/drafts/mysid-outline-plan-round-number.txt"
    if [[ -f "$EXPECTED" ]]; then
      pass "9b: outline counter at <plans>/drafts/<sid>-outline-plan-round-number.txt"
    else
      fail "9b: outline counter missing at $EXPECTED. Listing: $(ls "$PLANS/drafts/" 2>/dev/null)"
    fi
  }
else
  echo "SKIP-9b: outline wrapper not present"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
