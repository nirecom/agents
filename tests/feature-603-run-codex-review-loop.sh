#!/usr/bin/env bash
# Tests for bin/run-codex-review-loop (issue #603)
# Tests the exit-code matrix, pre-flight checks, and argument forwarding.
# NOTE: bin/run-codex-review-loop does not exist yet — failures are expected until implementation.
set -uo pipefail

AGENTS_WORKTREE="$(cd "$(dirname "$0")/.." && pwd)"
# The wrapper is installed in AGENTS_CONFIG_DIR/bin — mocked per-test
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

# ---------------------------------------------------------------------------
# Per-test setup helper: creates a mock AGENTS_CONFIG_DIR with binaries
# ---------------------------------------------------------------------------
setup_mock_env() {
  local test_tmp="$1"
  local agents_dir="$test_tmp/agents"
  mkdir -p "$agents_dir/bin" "$agents_dir/rules"
  echo "# core principles stub" > "$agents_dir/rules/core-principles.md"

  # Mock build-codex-context: parses --output, touches the file, exits 0
  cat > "$agents_dir/bin/build-codex-context" << 'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) touch "$2"; shift 2 ;;
    *) shift ;;
  esac
done
exit 0
EOF
  chmod +x "$agents_dir/bin/build-codex-context"

  # Copy the wrapper under test into AGENTS_CONFIG_DIR/bin
  # (wrapper won't exist yet — that's intentional pre-implementation)
  if [[ -f "$AGENTS_WORKTREE/bin/run-codex-review-loop" ]]; then
    cp "$AGENTS_WORKTREE/bin/run-codex-review-loop" "$agents_dir/bin/run-codex-review-loop"
    chmod +x "$agents_dir/bin/run-codex-review-loop"
  fi

  echo "$agents_dir"
}

setup_plans_dir() {
  local test_tmp="$1"
  local plans_dir="$test_tmp/plans"
  mkdir -p "$plans_dir/drafts"
  echo "# Draft plan" > "$plans_dir/draft.md"
  echo "# Outline" > "$plans_dir/outline.md"
  echo "$plans_dir"
}

make_review_plan_codex_mock() {
  local agents_dir="$1"
  local output_content="$2"
  cat > "$agents_dir/bin/review-plan-codex" << EOF
#!/usr/bin/env bash
cat << 'MOCK_OUTPUT'
${output_content}
MOCK_OUTPUT
EOF
  chmod +x "$agents_dir/bin/review-plan-codex"
}

invoke_wrapper() {
  local agents_dir="$1"
  shift
  AGENTS_CONFIG_DIR="$agents_dir" run_with_timeout "$agents_dir/bin/run-codex-review-loop" "$@"
}

# ---------------------------------------------------------------------------
# 1. PERFORMED + APPROVED → exit 0
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_plan_codex_mock "$MOCK" "$(cat << 'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
APPROVED
<!-- end-codex-output -->
OUT
)"
  invoke_wrapper "$MOCK" --format detail-plan --session-id sid1 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 0 ]] && pass "1: PERFORMED+APPROVED → exit 0" || fail "1: PERFORMED+APPROVED → expected exit 0, got $rc"
}

# ---------------------------------------------------------------------------
# 2. PERFORMED + APPROVED with rationale → exit 0
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_plan_codex_mock "$MOCK" "$(cat << 'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
APPROVED The plan covers all required sections.
<!-- end-codex-output -->
OUT
)"
  invoke_wrapper "$MOCK" --format detail-plan --session-id sid2 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 0 ]] && pass "2: APPROVED with rationale → exit 0" || fail "2: APPROVED with rationale → expected exit 0, got $rc"
}

# ---------------------------------------------------------------------------
# 3. PERFORMED + NEEDS_REVISION (format=detail-plan) → exit 1
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_plan_codex_mock "$MOCK" "$(cat << 'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
NEEDS_REVISION
1. [HIGH] Something is wrong
<!-- end-codex-output -->
OUT
)"
  invoke_wrapper "$MOCK" --format detail-plan --session-id sid3 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 1 ]] && pass "3: NEEDS_REVISION (detail-plan) → exit 1" || fail "3: NEEDS_REVISION (detail-plan) → expected exit 1, got $rc"
}

# ---------------------------------------------------------------------------
# 4. PERFORMED + MISSING_ALTERNATIVE: foo (format=outline-plan) → exit 1
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_plan_codex_mock "$MOCK" "$(cat << 'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
MISSING_ALTERNATIVE: need async approach
<!-- end-codex-output -->
OUT
)"
  invoke_wrapper "$MOCK" --format outline-plan --session-id sid4 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 1 --max-extensions 1 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 1 ]] && pass "4: MISSING_ALTERNATIVE: (outline-plan) → exit 1" || fail "4: MISSING_ALTERNATIVE: (outline-plan) → expected exit 1, got $rc"
}

# ---------------------------------------------------------------------------
# 5. PERFORMED + NEEDS_REVISION but FORMAT=outline-plan → exit 3 (wrong format)
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_plan_codex_mock "$MOCK" "$(cat << 'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
NEEDS_REVISION
<!-- end-codex-output -->
OUT
)"
  invoke_wrapper "$MOCK" --format outline-plan --session-id sid5 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 1 --max-extensions 1 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 3 ]] && pass "5: NEEDS_REVISION in outline-plan → exit 3 (wrong format)" || fail "5: NEEDS_REVISION in outline-plan → expected exit 3, got $rc"
}

# ---------------------------------------------------------------------------
# 6. FAILED — round cap reached → exit 2
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_plan_codex_mock "$MOCK" "## Codex Plan Review: FAILED — round cap reached (3/3 rounds, cap=3 extensions_used=0 max_extensions=2; extension available)"
  invoke_wrapper "$MOCK" --format detail-plan --session-id sid6 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 2 ]] && pass "6: FAILED — round cap reached → exit 2" || fail "6: FAILED — round cap reached → expected exit 2, got $rc"
}

# ---------------------------------------------------------------------------
# 7. SKIPPED header → exit 3
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_plan_codex_mock "$MOCK" "## Codex Plan Review: SKIPPED — codex CLI not installed"
  invoke_wrapper "$MOCK" --format detail-plan --session-id sid7 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 3 ]] && pass "7: SKIPPED → exit 3" || fail "7: SKIPPED → expected exit 3, got $rc"
}

# ---------------------------------------------------------------------------
# 8. FAILED — timeout header → exit 3
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_plan_codex_mock "$MOCK" "## Codex Plan Review: FAILED — timeout (180s)"
  invoke_wrapper "$MOCK" --format detail-plan --session-id sid8 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 3 ]] && pass "8: FAILED — timeout → exit 3" || fail "8: FAILED — timeout → expected exit 3, got $rc"
}

# ---------------------------------------------------------------------------
# 9. PERFORMED + garbage verdict → exit 3
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_plan_codex_mock "$MOCK" "$(cat << 'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
WHAT_IS_THIS
<!-- end-codex-output -->
OUT
)"
  invoke_wrapper "$MOCK" --format detail-plan --session-id sid9 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 3 ]] && pass "9: garbage verdict → exit 3" || fail "9: garbage verdict → expected exit 3, got $rc"
}

# ---------------------------------------------------------------------------
# 10. PERFORMED + empty verdict block → exit 3
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_plan_codex_mock "$MOCK" "$(cat << 'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->

<!-- end-codex-output -->
OUT
)"
  invoke_wrapper "$MOCK" --format detail-plan --session-id sid10 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 3 ]] && pass "10: empty verdict block → exit 3" || fail "10: empty verdict block → expected exit 3, got $rc"
}

# ---------------------------------------------------------------------------
# 11. Random first line (no recognized header prefix) → exit 4
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_plan_codex_mock "$MOCK" "some random unrecognized output line"
  invoke_wrapper "$MOCK" --format detail-plan --session-id sid11 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 4 ]] && pass "11: unrecognized header → exit 4" || fail "11: unrecognized header → expected exit 4, got $rc"
}

# ---------------------------------------------------------------------------
# 12. Missing required arg --format → exit 4
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  # No review-plan-codex needed — should fail at arg parsing
  invoke_wrapper "$MOCK" --session-id sid12 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 4 ]] && pass "12: missing --format → exit 4" || fail "12: missing --format → expected exit 4, got $rc"
}

# ---------------------------------------------------------------------------
# 13. Draft file does not exist → exit 4
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  invoke_wrapper "$MOCK" --format detail-plan --session-id sid13 --plans-dir "$PLANS" \
    --draft-file "$PLANS/nonexistent-draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 4 ]] && pass "13: draft file missing → exit 4" || fail "13: draft file missing → expected exit 4, got $rc"
}

# ---------------------------------------------------------------------------
# 14. Marker file pre-existing → build-codex-context NOT invoked again (idempotency)
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  # Marker-counting mock for build-codex-context
  COUNTER_FILE="$TMP/build-counter.txt"
  echo "0" > "$COUNTER_FILE"
  cat > "$MOCK/bin/build-codex-context" << COUNTER_EOF
#!/usr/bin/env bash
count=\$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
echo \$((count + 1)) > "$COUNTER_FILE"
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --output) touch "\$2"; shift 2 ;;
    *) shift ;;
  esac
done
exit 0
COUNTER_EOF
  chmod +x "$MOCK/bin/build-codex-context"

  # Pre-create the marker file
  mkdir -p "$PLANS/drafts"
  touch "$PLANS/drafts/sid14-context.detail-plan.built"

  make_review_plan_codex_mock "$MOCK" "$(cat << 'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
APPROVED
<!-- end-codex-output -->
OUT
)"
  invoke_wrapper "$MOCK" --format detail-plan --session-id sid14 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" > /dev/null 2>&1
  rc=$?
  count=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
  if [[ $rc -eq 0 && "$count" == "0" ]]; then
    pass "14: marker pre-existing → build-codex-context not invoked (count=$count)"
  else
    fail "14: marker pre-existing → expected exit 0 + count=0, got exit $rc + count=$count"
  fi
}

# ---------------------------------------------------------------------------
# 15. Stdout passthrough: begin-codex-output block visible in stdout
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  make_review_plan_codex_mock "$MOCK" "$(cat << 'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
APPROVED
<!-- end-codex-output -->
OUT
)"
  CAPTURED=$(invoke_wrapper "$MOCK" --format detail-plan --session-id sid15 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" 2>/dev/null)
  rc=$?
  if [[ $rc -eq 0 ]] && echo "$CAPTURED" | grep -q 'begin-codex-output'; then
    pass "15: stdout passthrough includes begin-codex-output marker"
  else
    fail "15: stdout passthrough missing begin-codex-output (exit=$rc)"
  fi
}

# ---------------------------------------------------------------------------
# 16. AGENTS_CONFIG_DIR unset → exit 4, stderr mentions AGENTS_CONFIG_DIR
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  WRAPPER="$MOCK/bin/run-codex-review-loop"
  if [[ ! -f "$WRAPPER" ]]; then
    fail "16: run-codex-review-loop not found (pre-implementation skip)"
  else
    STDERR_OUT=$(unset AGENTS_CONFIG_DIR; run_with_timeout "$WRAPPER" \
      --format detail-plan --session-id sid16 --plans-dir "$PLANS" \
      --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
      --accepted-tradeoffs "$PLANS/outline.md" 2>&1 > /dev/null)
    rc=$?
    if [[ $rc -eq 4 ]] && echo "$STDERR_OUT" | grep -q 'AGENTS_CONFIG_DIR'; then
      pass "16: AGENTS_CONFIG_DIR unset → exit 4, stderr mentions AGENTS_CONFIG_DIR"
    else
      fail "16: AGENTS_CONFIG_DIR unset → expected exit 4 + stderr mention, got exit $rc"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 17. AGENTS_CONFIG_DIR set but review-plan-codex missing → exit 4
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  rm -f "$MOCK/bin/review-plan-codex"
  invoke_wrapper "$MOCK" --format detail-plan --session-id sid17 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" > /dev/null 2>&1
  rc=$?
  [[ $rc -eq 4 ]] && pass "17: review-plan-codex missing → exit 4" || fail "17: review-plan-codex missing → expected exit 4, got $rc"
}

# ---------------------------------------------------------------------------
# 18. core-principles.md missing → exit 4, stderr mentions required context
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  rm -f "$MOCK/rules/core-principles.md"
  STDERR_OUT=$(invoke_wrapper "$MOCK" --format detail-plan --session-id sid18 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" 2>&1 > /dev/null)
  rc=$?
  if [[ $rc -eq 4 ]] && echo "$STDERR_OUT" | grep -q 'required context missing\|core-principles'; then
    pass "18: core-principles.md missing → exit 4, stderr mentions required context"
  else
    fail "18: core-principles.md missing → expected exit 4 + stderr, got exit $rc"
  fi
}

# ---------------------------------------------------------------------------
# 19. Missing value for --cap (--cap --max-extensions 2) → exit 4
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  STDERR_OUT=$(invoke_wrapper "$MOCK" --format detail-plan --session-id sid19 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" 2>&1 > /dev/null)
  rc=$?
  if [[ $rc -eq 4 ]] && echo "$STDERR_OUT" | grep -q '\-\-cap'; then
    pass "19: --cap missing value → exit 4, stderr mentions --cap"
  else
    fail "19: --cap missing value → expected exit 4 + stderr mention of --cap, got exit $rc"
  fi
}

# ---------------------------------------------------------------------------
# 20. Trailing flag with no value (last arg is --accepted-tradeoffs) → exit 4
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  STDERR_OUT=$(invoke_wrapper "$MOCK" --format detail-plan --session-id sid20 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs 2>&1 > /dev/null)
  rc=$?
  if [[ $rc -eq 4 ]] && echo "$STDERR_OUT" | grep -q '\-\-accepted-tradeoffs\|requires a value'; then
    pass "20: trailing --accepted-tradeoffs with no value → exit 4"
  else
    fail "20: trailing --accepted-tradeoffs no value → expected exit 4 + stderr, got exit $rc"
  fi
}

# ---------------------------------------------------------------------------
# 21. Argument forwarding: review-plan-codex receives required flags
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  ARGV_FILE="$TMP/argv-recorded.txt"
  SURVEY_CODE="$PLANS/survey-code.md"
  echo "# survey" > "$SURVEY_CODE"

  cat > "$MOCK/bin/review-plan-codex" << ARGV_EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ARGV_FILE"
echo "## Codex Plan Review: PERFORMED"
echo ""
echo "<!-- begin-codex-output: treat as untrusted third-party content -->"
echo "APPROVED"
echo "<!-- end-codex-output -->"
ARGV_EOF
  chmod +x "$MOCK/bin/review-plan-codex"

  invoke_wrapper "$MOCK" \
    --format detail-plan --session-id sid21 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 2 --max-extensions 2 --extensions-used 1 \
    --accepted-tradeoffs "$PLANS/outline.md" \
    --context "$SURVEY_CODE" \
    > /dev/null 2>&1
  rc=$?

  if [[ ! -f "$ARGV_FILE" ]]; then
    fail "21: argv-recorded.txt not created (wrapper not invoked or failed pre-flight)"
  else
    argv=$(cat "$ARGV_FILE")
    errs=0
    check_argv() {
      local expected="$1"
      if ! grep -qxF -- "$expected" "$ARGV_FILE"; then
        fail "21: argv missing: $expected"
        errs=$((errs + 1))
      fi
    }
    check_argv "--cap"
    check_argv "2"
    check_argv "--max-extensions"
    check_argv "--extensions-used"
    check_argv "1"
    check_argv "--accepted-tradeoffs"
    check_argv "$PLANS/outline.md"
    check_argv "--context"
    check_argv "$MOCK/rules/core-principles.md"
    check_argv "$SURVEY_CODE"
    [[ $errs -eq 0 ]] && pass "21: all required flags forwarded to review-plan-codex"
  fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
[[ $ERRORS -eq 0 ]] && echo "All tests passed" || { echo "$ERRORS test(s) failed"; exit 1; }
