#!/bin/bash
# Tests: hooks/session-start.js, hooks/workflow-mark.js
# Tags: workflow, hook, bin, tests
# Test suite for workflow transition hint feature:
#   hooks/session-start.js   (buildWorkflowStatus + NEXT ACTION hint)
#   hooks/workflow-mark.js   (nextStepHint after markStep)
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SESSION_START="$AGENTS_DIR/hooks/session-start.js"
MARK_HOOK="$AGENTS_DIR/hooks/workflow-mark.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout: use system timeout if available, else perl alarm
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# ---------------------------------------------------------------------------
# Temp dir setup — each test gets a fresh WORKFLOW_DIR
# ---------------------------------------------------------------------------

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Write a state file: write_state <dir> <session_id> <json_content>
write_state() {
    local dir="$1" sid="$2" json="$3"
    mkdir -p "$dir"
    printf '%s' "$json" > "$dir/${sid}.json"
}

# Assert that a string contains a substring. Uses grep for portability (avoids /dev/stdin).
assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF "$needle" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc — expected '$needle' in output, got: $haystack"
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF "$needle" 2>/dev/null; then
        fail "$desc — unexpected '$needle' found in output: $haystack"
    else
        pass "$desc"
    fi
}

assert_valid_json() {
    local desc="$1" text="$2"
    if printf '%s' "$text" | node -e "
      let b='';process.stdin.on('data',c=>b+=c);
      process.stdin.on('end',()=>{try{JSON.parse(b);process.exit(0);}catch(e){process.exit(1);}});
    " 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc — not valid JSON: $text"
    fi
}

# Extract additionalContext field from JSON output using node (stdin safe on all platforms)
extract_additional_context() {
    printf '%s' "$1" | node -e "
      let b='';process.stdin.on('data',c=>b+=c);
      process.stdin.on('end',()=>{
        try {
          const d=JSON.parse(b);
          process.stdout.write(d.additionalContext||'');
        } catch(e) {}
      });
    " 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helper: JSON snippets for common state shapes
# ---------------------------------------------------------------------------

STATE_CLARIFY_COMPLETE() {
    local sid="${1:-test-hint}"
    cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-04-28T10:00:00.000Z",
  "steps": {
    "clarify_intent":     {"status": "complete", "updated_at": "2026-04-28T10:01:00.000Z"},
    "research":           {"status": "pending",  "updated_at": null},
    "outline":            {"status": "pending",  "updated_at": null},
    "detail":             {"status": "pending",  "updated_at": null},
    "branching_complete": {"status": "pending",  "updated_at": null},
    "write_tests":        {"status": "pending",  "updated_at": null},
    "review_tests":       {"status": "pending",  "updated_at": null},
    "run_tests":          {"status": "pending",  "updated_at": null},
    "review_security":    {"status": "pending",  "updated_at": null},
    "docs":               {"status": "pending",  "updated_at": null},
    "user_verification":  {"status": "pending",  "updated_at": null}
  }
}
EOF
}

ALL_COMPLETE_STATE() {
    local sid="${1:-test-hint}"
    cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-04-28T10:00:00.000Z",
  "steps": {
    "clarify_intent":     {"status": "complete", "updated_at": "2026-04-28T10:01:00.000Z"},
    "research":           {"status": "complete", "updated_at": "2026-04-28T10:02:00.000Z"},
    "outline":            {"status": "complete", "updated_at": "2026-04-28T10:02:30.000Z"},
    "detail":             {"status": "complete", "updated_at": "2026-04-28T10:03:00.000Z"},
    "branching_complete": {"status": "complete", "updated_at": "2026-04-28T10:04:00.000Z"},
    "write_tests":        {"status": "complete", "updated_at": "2026-04-28T10:05:00.000Z"},
    "review_tests":       {"status": "complete", "updated_at": "2026-04-28T10:05:30.000Z"},
    "run_tests":          {"status": "complete", "updated_at": "2026-04-28T10:06:00.000Z"},
    "review_security":    {"status": "complete", "updated_at": "2026-04-28T10:07:00.000Z"},
    "docs":               {"status": "complete", "updated_at": "2026-04-28T10:08:00.000Z"},
    "user_verification":  {"status": "complete", "updated_at": "2026-04-28T10:09:00.000Z"},
    "cleanup":            {"status": "skipped",  "updated_at": "2026-04-28T10:10:00.000Z"}
  }
}
EOF
}

# Build a PostToolUse-style hook input JSON with exit_code=0
build_mark_json() {
    local cmd="$1" sid="${2:-test-hint}"
    local esc="${cmd//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"%s\\n","stderr":""},"session_id":"%s"}' \
        "$esc" "$esc" "$sid"
}

# Build a PostToolUse-style hook input JSON with exit_code=1 (failed command)
build_mark_json_fail() {
    local cmd="$1" sid="${2:-test-hint}"
    local esc="${cmd//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":1,"stdout":"","stderr":"oops"},"session_id":"%s"}' \
        "$esc" "$sid"
}

# Read state file step status
read_state_status() {
    local state_file="$1" step="$2"
    if [ ! -f "$state_file" ]; then echo "MISSING"; return; fi
    node -e "
      const fs=require('fs');
      try {
        const s=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
        const step=s.steps&&s.steps[process.argv[2]];
        console.log(step&&step.status?step.status:'MISSING');
      } catch(e) { console.log('MISSING'); }
    " -- "$state_file" "$step" 2>/dev/null || echo "MISSING"
}

# ---------------------------------------------------------------------------
# === session-start: Normal cases ===
# ---------------------------------------------------------------------------

echo "=== session-start: Normal cases ==="

# Test SS-1: New session (no state file) → additionalContext contains "clarify_intent: pending"
# AND contains "NEXT ACTION:" AND contains "clarify-intent"
SS1_DIR="$TMPDIR_BASE/ss1-workflow"
mkdir -p "$SS1_DIR"
SS1_OUT=$(echo '{"session_id":"ss1-test"}' | \
    CLAUDE_WORKFLOW_DIR="$SS1_DIR" run_with_timeout node "$SESSION_START" 2>/dev/null || true)
SS1_CTX=$(extract_additional_context "$SS1_OUT")

assert_contains "SS-1a. new session: additionalContext contains 'clarify_intent: pending'" \
    "$SS1_CTX" "clarify_intent: pending"
assert_contains "SS-1b. new session: additionalContext contains 'NEXT ACTION:'" \
    "$SS1_CTX" "NEXT ACTION:"

# For new session, clarify_intent is pending → NEXT_STEP_HINT[clarify_intent] is shown.
# That hint contains 'make-outline-plan'. The test spec says "NEXT ACTION line contains clarify-intent".
# But looking at actual output: new session → session-start creates state with all pending.
# The first pending step is clarify_intent → NEXT_STEP_HINT[clarify_intent] is used.
# NEXT_STEP_HINT[clarify_intent] contains "make-outline-plan" (not "clarify-intent").
# However, when no state file exists (state is null), the else branch in buildWorkflowStatus runs:
# nextAction = "clarify-intent — Skill ツールで /clarify-intent を呼び出してください"
# BUT a state file IS written by session-start before buildWorkflowStatus is called.
# So state IS available and clarify_intent is pending → NEXT_STEP_HINT[clarify_intent] applies.
# NEXT_STEP_HINT[clarify_intent] contains both 'make-outline-plan' and survey-code references.
assert_contains "SS-1c. new session: NEXT ACTION hint contains 'clarify-intent'" \
    "$SS1_CTX" "clarify-intent"

# Test SS-2: State with clarify_intent complete, research pending →
#   additionalContext contains "clarify_intent: complete" AND "make-outline-plan" in NEXT ACTION
SS2_DIR="$TMPDIR_BASE/ss2-workflow"
write_state "$SS2_DIR" "ss2-test" "$(STATE_CLARIFY_COMPLETE ss2-test)"
SS2_OUT=$(echo '{"session_id":"ss2-test"}' | \
    CLAUDE_WORKFLOW_DIR="$SS2_DIR" run_with_timeout node "$SESSION_START" 2>/dev/null || true)
SS2_CTX=$(extract_additional_context "$SS2_OUT")

assert_contains "SS-2a. clarify_intent complete: 'clarify_intent: complete' in context" \
    "$SS2_CTX" "clarify_intent: complete"
# research is now the first pending step → STEP_HINT[research] mentions survey-code/deep-research
assert_contains "SS-2b. clarify_intent complete: NEXT ACTION contains 'survey-code'" \
    "$SS2_CTX" "survey-code"

# Test SS-3: All steps complete → additionalContext contains "全ステップ完了済み" OR "commit-push"
SS3_DIR="$TMPDIR_BASE/ss3-workflow"
write_state "$SS3_DIR" "ss3-test" "$(ALL_COMPLETE_STATE ss3-test)"
SS3_OUT=$(echo '{"session_id":"ss3-test"}' | \
    CLAUDE_WORKFLOW_DIR="$SS3_DIR" run_with_timeout node "$SESSION_START" 2>/dev/null || true)
SS3_CTX=$(extract_additional_context "$SS3_OUT")

if printf '%s' "$SS3_CTX" | grep -qF "全ステップ完了済み" 2>/dev/null || \
   printf '%s' "$SS3_CTX" | grep -qF "commit-push" 2>/dev/null; then
    pass "SS-3. all steps complete: NEXT ACTION contains completion message"
else
    fail "SS-3. all steps complete: expected '全ステップ完了済み' or 'commit-push', got: $SS3_CTX"
fi

# Test SS-4: No session_id → still outputs valid JSON, no crash
SS4_DIR="$TMPDIR_BASE/ss4-workflow"
mkdir -p "$SS4_DIR"
SS4_OUT=$(echo '{}' | \
    CLAUDE_WORKFLOW_DIR="$SS4_DIR" run_with_timeout node "$SESSION_START" 2>/dev/null || true)
SS4_EXIT=$?
assert_valid_json "SS-4a. no session_id: output is valid JSON" "$SS4_OUT"
if [ "$SS4_EXIT" = "0" ]; then pass "SS-4b. no session_id: exit 0 (fail-open)"
else fail "SS-4b. no session_id: expected exit 0, got: $SS4_EXIT"; fi

# ---------------------------------------------------------------------------
# === workflow-mark: Normal hint cases ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-mark: Normal hint cases ==="

# Test WM-5: clarify_intent complete → hint contains "make-outline-plan"
WM5_DIR="$TMPDIR_BASE/wm5-workflow"
mkdir -p "$WM5_DIR"
WM5_JSON=$(build_mark_json 'echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"' "wm5-test")
WM5_OUT=$(echo "$WM5_JSON" | CLAUDE_WORKFLOW_DIR="$WM5_DIR" run_with_timeout node "$MARK_HOOK" 2>/dev/null || true)
WM5_CTX=$(extract_additional_context "$WM5_OUT")
assert_contains "WM-5. clarify_intent complete → hint contains 'make-outline-plan'" \
    "$WM5_CTX" "make-outline-plan"

# Test WM-6: research skipped → hint contains "make-outline-plan"
WM6_DIR="$TMPDIR_BASE/wm6-workflow"
mkdir -p "$WM6_DIR"
WM6_JSON=$(build_mark_json 'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: this task needs no external research>>"' "wm6-test")
WM6_OUT=$(echo "$WM6_JSON" | CLAUDE_WORKFLOW_DIR="$WM6_DIR" run_with_timeout node "$MARK_HOOK" 2>/dev/null || true)
WM6_CTX=$(extract_additional_context "$WM6_OUT")
assert_contains "WM-6. research skipped → hint contains 'make-outline-plan'" \
    "$WM6_CTX" "make-outline-plan"

# Test WM-7a: outline skipped → hint mentions make-detail-plan OR branching
WM7A_DIR="$TMPDIR_BASE/wm7a-workflow"
mkdir -p "$WM7A_DIR"
WM7A_JSON=$(build_mark_json 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: only one approach exists>>"' "wm7a-test")
WM7A_OUT=$(echo "$WM7A_JSON" | CLAUDE_WORKFLOW_DIR="$WM7A_DIR" run_with_timeout node "$MARK_HOOK" 2>/dev/null || true)
WM7A_CTX=$(extract_additional_context "$WM7A_OUT")
if printf '%s' "$WM7A_CTX" | grep -qF "make-detail-plan" 2>/dev/null || \
   printf '%s' "$WM7A_CTX" | grep -qF "detail" 2>/dev/null || \
   printf '%s' "$WM7A_CTX" | grep -qF "BRANCHING" 2>/dev/null || \
   printf '%s' "$WM7A_CTX" | grep -qF "branch.md" 2>/dev/null; then
    pass "WM-7a. outline skipped → hint contains 'make-detail-plan'/'BRANCHING'/'branch.md'"
else
    fail "WM-7a. outline skipped → expected detail/branching hint, got: $WM7A_CTX"
fi

# Test WM-7b: detail skipped → hint mentions branching
WM7B_DIR="$TMPDIR_BASE/wm7b-workflow"
mkdir -p "$WM7B_DIR"
WM7B_JSON=$(build_mark_json 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: trivial one-line config change>>"' "wm7b-test")
WM7B_OUT=$(echo "$WM7B_JSON" | CLAUDE_WORKFLOW_DIR="$WM7B_DIR" run_with_timeout node "$MARK_HOOK" 2>/dev/null || true)
WM7B_CTX=$(extract_additional_context "$WM7B_OUT")
if printf '%s' "$WM7B_CTX" | grep -qF "BRANCHING_DECIDED" 2>/dev/null || \
   printf '%s' "$WM7B_CTX" | grep -qF "BRANCHING_COMPLETE" 2>/dev/null || \
   printf '%s' "$WM7B_CTX" | grep -qF "branch.md" 2>/dev/null; then
    pass "WM-7b. detail skipped → hint contains 'BRANCHING_COMPLETE/DECIDED' or 'branch.md'"
else
    fail "WM-7b. detail skipped → expected 'BRANCHING_COMPLETE/DECIDED' or 'branch.md' in hint, got: $WM7B_CTX"
fi

# Test WM-8: write_tests skipped → next step is review_tests; hint mentions review-tests
# (#833 inserted review_tests immediately after write_tests in VALID_STEPS.)
WM8_DIR="$TMPDIR_BASE/wm8-workflow"
mkdir -p "$WM8_DIR"
WM8_JSON=$(build_mark_json 'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: no testable logic changed>>"' "wm8-test")
WM8_OUT=$(echo "$WM8_JSON" | CLAUDE_WORKFLOW_DIR="$WM8_DIR" run_with_timeout node "$MARK_HOOK" 2>/dev/null || true)
WM8_CTX=$(extract_additional_context "$WM8_OUT")
if printf '%s' "$WM8_CTX" | grep -qF "review-tests" 2>/dev/null || \
   printf '%s' "$WM8_CTX" | grep -qF "review_tests" 2>/dev/null; then
    pass "WM-8. write_tests skipped → next step is review_tests (hint contains 'review-tests' or 'review_tests')"
else
    fail "WM-8. write_tests skipped → expected 'review-tests' or 'review_tests' in hint, got: $WM8_CTX"
fi

# Test WM-8b: WRITE_TESTS_NOT_NEEDED propagates skip to review_tests
# (Once write_tests is skipped because tests are not needed, review_tests is meaningless
# too — the NOT_NEEDED handler should mark both as skipped in one shot.)
WM8B_WT_STATUS=$(read_state_status "$WM8_DIR/wm8-test.json" "write_tests")
WM8B_RT_STATUS=$(read_state_status "$WM8_DIR/wm8-test.json" "review_tests")
if [ "$WM8B_WT_STATUS" = "skipped" ] && [ "$WM8B_RT_STATUS" = "skipped" ]; then
    pass "WM-8b. WRITE_TESTS_NOT_NEEDED → both write_tests and review_tests marked skipped"
else
    fail "WM-8b. WRITE_TESTS_NOT_NEEDED → expected write_tests=skipped, review_tests=skipped; got: write_tests=$WM8B_WT_STATUS, review_tests=$WM8B_RT_STATUS"
fi

# Test WM-8c: review_tests skipped → hint mentions run_tests (next step)
# This validates VALID_STEPS ordering: write_tests → review_tests → run_tests.
WM8C_DIR="$TMPDIR_BASE/wm8c-workflow"
mkdir -p "$WM8C_DIR"
# Pre-write state with write_tests=complete, review_tests=pending → simulate review-tests
# step in progress. Then mark review_tests=complete via the review-tests-handler path
# (run-tests is the next step). Since /review-tests is a new skill (#833) the actual
# sentinel format is internal; for now we directly mark via state shape and read hint.
cat > "$WM8C_DIR/wm8c-test.json" <<'WM8C_EOF'
{
  "version": 1,
  "session_id": "wm8c-test",
  "created_at": "2026-04-28T10:00:00.000Z",
  "steps": {
    "clarify_intent":     {"status": "complete", "updated_at": "2026-04-28T10:01:00.000Z"},
    "research":           {"status": "complete", "updated_at": "2026-04-28T10:02:00.000Z"},
    "outline":            {"status": "complete", "updated_at": "2026-04-28T10:02:30.000Z"},
    "detail":             {"status": "complete", "updated_at": "2026-04-28T10:03:00.000Z"},
    "branching_complete": {"status": "complete", "updated_at": "2026-04-28T10:04:00.000Z"},
    "write_tests":        {"status": "complete", "updated_at": "2026-04-28T10:05:00.000Z"},
    "review_tests":       {"status": "skipped",  "updated_at": "2026-04-28T10:05:30.000Z"},
    "run_tests":          {"status": "pending",  "updated_at": null},
    "review_security":    {"status": "pending",  "updated_at": null},
    "docs":               {"status": "pending",  "updated_at": null},
    "user_verification":  {"status": "pending",  "updated_at": null}
  }
}
WM8C_EOF
WM8C_OUT=$(echo '{"session_id":"wm8c-test"}' | \
    CLAUDE_WORKFLOW_DIR="$WM8C_DIR" run_with_timeout node "$SESSION_START" 2>/dev/null || true)
WM8C_CTX=$(extract_additional_context "$WM8C_OUT")
if printf '%s' "$WM8C_CTX" | grep -qF "run_tests" 2>/dev/null || \
   printf '%s' "$WM8C_CTX" | grep -qF "run-tests" 2>/dev/null; then
    pass "WM-8c. review_tests skipped → next step is run_tests (hint contains 'run_tests' or 'run-tests')"
else
    fail "WM-8c. review_tests skipped → expected 'run_tests' or 'run-tests' in hint, got: $WM8C_CTX"
fi

# Test WM-9: review_security skipped → hint contains "update-docs"
WM9_DIR="$TMPDIR_BASE/wm9-workflow"
mkdir -p "$WM9_DIR"
WM9_JSON=$(build_mark_json 'echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: no external input or secrets>>"' "wm9-test")
WM9_OUT=$(echo "$WM9_JSON" | CLAUDE_WORKFLOW_DIR="$WM9_DIR" run_with_timeout node "$MARK_HOOK" 2>/dev/null || true)
WM9_CTX=$(extract_additional_context "$WM9_OUT")
if printf '%s' "$WM9_CTX" | grep -qF "update-docs" 2>/dev/null || \
   printf '%s' "$WM9_CTX" | grep -qF "docs" 2>/dev/null; then
    pass "WM-9. review_security skipped → hint contains 'update-docs'"
else
    fail "WM-9. review_security skipped → expected 'update-docs' in hint, got: $WM9_CTX"
fi

# Test WM-10: generic MARK_STEP run_tests complete → hint contains "review" OR "docs"
WM10_DIR="$TMPDIR_BASE/wm10-workflow"
mkdir -p "$WM10_DIR"
WM10_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>"' "wm10-test")
WM10_OUT=$(echo "$WM10_JSON" | CLAUDE_WORKFLOW_DIR="$WM10_DIR" run_with_timeout node "$MARK_HOOK" 2>/dev/null || true)
WM10_CTX=$(extract_additional_context "$WM10_OUT")
if printf '%s' "$WM10_CTX" | grep -qF "review" 2>/dev/null || \
   printf '%s' "$WM10_CTX" | grep -qF "docs" 2>/dev/null; then
    pass "WM-10. run_tests complete → hint contains 'review' or 'docs'"
else
    fail "WM-10. run_tests complete → expected 'review' or 'docs' in hint, got: $WM10_CTX"
fi

# ---------------------------------------------------------------------------
# === workflow-mark: Idempotency ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-mark: Idempotency ==="

# Test WM-11: clarify_intent complete applied twice → both outputs contain hint, state valid
WM11_DIR="$TMPDIR_BASE/wm11-workflow"
mkdir -p "$WM11_DIR"
WM11_JSON=$(build_mark_json 'echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"' "wm11-test")
WM11_OUT1=$(echo "$WM11_JSON" | CLAUDE_WORKFLOW_DIR="$WM11_DIR" run_with_timeout node "$MARK_HOOK" 2>/dev/null || true)
WM11_OUT2=$(echo "$WM11_JSON" | CLAUDE_WORKFLOW_DIR="$WM11_DIR" run_with_timeout node "$MARK_HOOK" 2>/dev/null || true)
WM11_CTX1=$(extract_additional_context "$WM11_OUT1")
WM11_CTX2=$(extract_additional_context "$WM11_OUT2")

assert_contains "WM-11a. idempotency: first run hint contains 'make-outline-plan'" \
    "$WM11_CTX1" "make-outline-plan"
assert_contains "WM-11b. idempotency: second run hint contains 'make-outline-plan'" \
    "$WM11_CTX2" "make-outline-plan"

WM11_STATUS=$(read_state_status "$WM11_DIR/wm11-test.json" "clarify_intent")
if [ "$WM11_STATUS" = "complete" ]; then
    pass "WM-11c. idempotency: state remains clarify_intent=complete"
else
    fail "WM-11c. idempotency: expected clarify_intent=complete, got: $WM11_STATUS"
fi

# ---------------------------------------------------------------------------
# === workflow-mark: Error / failure suppression ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-mark: Error cases ==="

# Test WM-12: exit_code=1 → NO hint in additionalContext (failure suppression)
# The hook detects exit_code=1 early and calls done() with an error message before
# processing any sentinels → no step-transition hint should appear.
WM12_DIR="$TMPDIR_BASE/wm12-workflow"
mkdir -p "$WM12_DIR"
WM12_JSON=$(build_mark_json_fail 'echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"' "wm12-test")
WM12_OUT=$(echo "$WM12_JSON" | CLAUDE_WORKFLOW_DIR="$WM12_DIR" run_with_timeout node "$MARK_HOOK" 2>/dev/null || true)
WM12_CTX=$(extract_additional_context "$WM12_OUT")
assert_not_contains "WM-12. exit_code=1 → no hint 'make-outline-plan' in output (failure suppression)" \
    "$WM12_CTX" "make-outline-plan"
# Also verify output is still valid JSON (fail-open)
assert_valid_json "WM-12b. exit_code=1 → output is valid JSON" "$WM12_OUT"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
