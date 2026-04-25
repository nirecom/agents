#!/bin/bash
# Tests for:
#  Bug 1: workflow-mark.js must handle sentinels chained with `&&` in one
#         Bash call (split on \s*&&\s* and evaluate each part).
#  Bug 2: workflow-gate.js SKILL_MAP must contain `run_tests` and `review_security`
#         entries so the block reason gives actionable guidance instead
#         of the generic MARK_STEP_<step>_complete fallback.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE_HOOK="$DOTFILES_DIR/claude-global/hooks/workflow-gate.js"
MARK_HOOK="$DOTFILES_DIR/claude-global/hooks/workflow-mark.js"
ERRORS=0
FAILED_IDS=()
PASSED_IDS=()

fail() {
    echo "FAIL: $1"
    ERRORS=$((ERRORS + 1))
    FAILED_IDS+=("$1")
}
pass() {
    echo "PASS: $1"
    PASSED_IDS+=("$1")
}

# Portable timeout wrapper (macOS has no `timeout` by default)
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE=$(mktemp -d)
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

setup_repo() {
    local repo="$TMPDIR_BASE/repo-$RANDOM"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

write_state() {
    local sid="$1" json="$2"
    mkdir -p "$WORKFLOW_DIR"
    printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

read_state_status() {
    local sid="$1" step="$2"
    local state_file="$WORKFLOW_DIR/${sid}.json"
    if [ ! -f "$state_file" ]; then echo "MISSING"; return; fi
    node -e "
      try {
        const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
        const step = s.steps && s.steps['$step'];
        console.log(step && step.status ? step.status : 'MISSING');
      } catch (e) { console.log('MISSING'); }
    " "$state_file" 2>/dev/null || echo "MISSING"
}

read_state_field() {
    local sid="$1" step="$2" field="$3"
    local state_file="$WORKFLOW_DIR/${sid}.json"
    if [ ! -f "$state_file" ]; then echo "MISSING"; return; fi
    node -e "
      try {
        const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
        const step = s.steps && s.steps['$step'];
        if (!step || step['$field'] === undefined || step['$field'] === null) {
          console.log('MISSING');
        } else {
          console.log(step['$field']);
        }
      } catch (e) { console.log('MISSING'); }
    " "$state_file" 2>/dev/null || echo "MISSING"
}

expect_state_step() {
    local desc="$1" sid="$2" step="$3" expected="$4"
    local actual
    actual=$(read_state_status "$sid" "$step")
    if [ "$actual" = "$expected" ]; then pass "$desc"
    else fail "$desc — expected steps.$step.status=$expected, got: $actual"; fi
}

# Build a state JSON where a single named step is given a raw object JSON literal.
build_state_with_override() {
    local sid="$1" step="$2" override_json="$3"
    node -e "
      const sid = process.argv[1];
      const step = process.argv[2];
      const override = JSON.parse(process.argv[3]);
      const STEPS = ['research','plan','write_tests','run_tests','review_security','docs','user_verification'];
      const steps = {};
      for (const s of STEPS) {
        steps[s] = { status: 'complete', updated_at: '2026-04-11T10:00:00.000Z' };
      }
      steps[step] = override;
      const state = {
        version: 1,
        session_id: sid,
        created_at: '2026-04-11T10:00:00.000Z',
        steps,
      };
      console.log(JSON.stringify(state, null, 2));
    " "$sid" "$step" "$override_json"
}

# Build a state JSON where MULTIPLE named steps are each given an override.
# Usage: build_state_with_multi_override SID STEP1 JSON1 STEP2 JSON2 ...
build_state_with_multi_override() {
    local sid="$1"; shift
    local args=("$sid")
    args+=("$#")
    while [ $# -gt 0 ]; do
        args+=("$1")
        shift
    done
    node -e "
      const sid = process.argv[1];
      const n = parseInt(process.argv[2], 10);
      const STEPS = ['research','plan','write_tests','run_tests','review_security','docs','user_verification'];
      const steps = {};
      for (const s of STEPS) {
        steps[s] = { status: 'complete', updated_at: '2026-04-11T10:00:00.000Z' };
      }
      for (let i = 0; i < n; i += 2) {
        const step = process.argv[3 + i];
        const override = JSON.parse(process.argv[3 + i + 1]);
        steps[step] = override;
      }
      const state = {
        version: 1,
        session_id: sid,
        created_at: '2026-04-11T10:00:00.000Z',
        steps,
      };
      console.log(JSON.stringify(state, null, 2));
    " "${args[@]}"
}

to_node_path() {
    cygpath -m "$1" 2>/dev/null || echo "$1"
}

run_gate() {
    local json="$1"
    echo "$json" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$GATE_HOOK" 2>/dev/null
}

run_mark() {
    local json="$1"
    echo "$json" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$MARK_HOOK" 2>/dev/null || true
}

build_mark_json() {
    local cmd="$1" sid="${2:-test-session}" exit_code="${3:-0}"
    local esc=${cmd//\\/\\\\}
    esc=${esc//\"/\\\"}
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":%s,"stdout":"%s\\n","stderr":""},"session_id":"%s"}' \
        "$esc" "$exit_code" "$esc" "$sid"
}

# State JSON where all steps are complete EXCEPT a given step (pending)
ALL_COMPLETE_EXCEPT() {
    local except_step="$1" sid="${2:-test-session}"
    local research_status plan_status write_tests_status run_tests_status review_security_status docs_status user_ver_status
    research_status=$([ "$except_step" = "research" ] && echo "pending" || echo "complete")
    plan_status=$([ "$except_step" = "plan" ] && echo "pending" || echo "complete")
    write_tests_status=$([ "$except_step" = "write_tests" ] && echo "pending" || echo "complete")
    run_tests_status=$([ "$except_step" = "run_tests" ] && echo "pending" || echo "complete")
    review_security_status=$([ "$except_step" = "review_security" ] && echo "pending" || echo "complete")
    docs_status=$([ "$except_step" = "docs" ] && echo "pending" || echo "complete")
    user_ver_status=$([ "$except_step" = "user_verification" ] && echo "pending" || echo "complete")
    cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "$research_status", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "$plan_status", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "$write_tests_status", "updated_at": "2026-04-11T10:03:00.000Z"},
    "run_tests":         {"status": "$run_tests_status", "updated_at": "2026-04-11T10:04:00.000Z"},
    "review_security":   {"status": "$review_security_status", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "$docs_status", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "$user_ver_status", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
}

ALL_PENDING_EXCEPT_LATER() {
    # research, plan, write_tests = pending; run_tests, review_security, docs, user_verification = complete
    local sid="${1:-test-session}"
    cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "pending", "updated_at": null},
    "plan":              {"status": "pending", "updated_at": null},
    "write_tests":       {"status": "pending", "updated_at": null},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
}

# ===========================================================================
# Bug 1 — `&&`-chain handling in workflow-mark.js
# ===========================================================================

echo ""
echo "=== WS-AND-H1: RESEARCH_NOT_NEEDED && PLAN_NOT_NEEDED in one Bash call ==="

SID="and-h1-$$"
# Start where research AND plan are both pending (others complete)
cat > "$WORKFLOW_DIR/${SID}.json" <<H1_EOF
{
  "version": 1,
  "session_id": "$SID",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "pending", "updated_at": null},
    "plan":              {"status": "pending", "updated_at": null},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
H1_EOF

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: single file change>>" && echo "<<WORKFLOW_PLAN_NOT_NEEDED: trivial typo fix>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

expect_state_step "WS-AND-H1a. research=skipped after chain" "$SID" "research" "skipped"
H1_R_REASON=$(read_state_field "$SID" "research" "skip_reason")
if [ "$H1_R_REASON" = "single file change" ]; then
    pass "WS-AND-H1b. research.skip_reason='single file change'"
else
    fail "WS-AND-H1b. expected 'single file change', got: $H1_R_REASON"
fi

expect_state_step "WS-AND-H1c. plan=skipped after chain" "$SID" "plan" "skipped"
H1_P_REASON=$(read_state_field "$SID" "plan" "skip_reason")
if [ "$H1_P_REASON" = "trivial typo fix" ]; then
    pass "WS-AND-H1d. plan.skip_reason='trivial typo fix'"
else
    fail "WS-AND-H1d. expected 'trivial typo fix', got: $H1_P_REASON"
fi

echo ""
echo "=== WS-AND-H2: three-way chain: RESEARCH && PLAN && WRITE_TESTS NOT_NEEDED ==="

SID="and-h2-$$"
write_state "$SID" "$(ALL_PENDING_EXCEPT_LATER "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: single file change>>" && echo "<<WORKFLOW_PLAN_NOT_NEEDED: trivial typo fix>>" && echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: pure config change>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

expect_state_step "WS-AND-H2a. research=skipped after 3-way chain" "$SID" "research" "skipped"
H2_R=$(read_state_field "$SID" "research" "skip_reason")
if [ "$H2_R" = "single file change" ]; then
    pass "WS-AND-H2b. research.skip_reason='single file change'"
else
    fail "WS-AND-H2b. expected 'single file change', got: $H2_R"
fi

expect_state_step "WS-AND-H2c. plan=skipped after 3-way chain" "$SID" "plan" "skipped"
H2_P=$(read_state_field "$SID" "plan" "skip_reason")
if [ "$H2_P" = "trivial typo fix" ]; then
    pass "WS-AND-H2d. plan.skip_reason='trivial typo fix'"
else
    fail "WS-AND-H2d. expected 'trivial typo fix', got: $H2_P"
fi

expect_state_step "WS-AND-H2e. write_tests=skipped after 3-way chain" "$SID" "write_tests" "skipped"
H2_W=$(read_state_field "$SID" "write_tests" "skip_reason")
if [ "$H2_W" = "pure config change" ]; then
    pass "WS-AND-H2f. write_tests.skip_reason='pure config change'"
else
    fail "WS-AND-H2f. expected 'pure config change', got: $H2_W"
fi

echo ""
echo "=== WS-AND-H3: non-sentinel && sentinel — whole chain rejected (all-or-nothing) ==="

SID="and-h3-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT research "$SID")"

MARK_JSON=$(build_mark_json 'echo hello && echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: single file change>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

expect_state_step "WS-AND-H3a. research stays pending (mixed chain rejected)" "$SID" "research" "pending"

# Also cover: `cd /tmp && echo "<<sentinel>>"` prefix-chain is rejected
SID="and-h3b-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT research "$SID")"
MARK_JSON=$(build_mark_json 'cd /tmp && echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: single file change>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")
expect_state_step "WS-AND-H3b. cd-prefix chain rejected → research stays pending" "$SID" "research" "pending"

echo ""
echo "=== WS-AND-H4: MARK_STEP_run_tests_complete && MARK_STEP_review_security_complete ==="

SID="and-h4-$$"
# run_tests AND review_security both pending (others complete)
cat > "$WORKFLOW_DIR/${SID}.json" <<H4_EOF
{
  "version": 1,
  "session_id": "$SID",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "run_tests":         {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "pending",  "updated_at": null},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
H4_EOF

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>" && echo "<<WORKFLOW_MARK_STEP_review_security_complete>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

expect_state_step "WS-AND-H4a. run_tests=complete after chain" "$SID" "run_tests" "complete"
expect_state_step "WS-AND-H4b. review_security=complete after chain" "$SID" "review_security" "complete"

echo ""
echo "=== WS-AND-E1: one valid, one malformed — valid processed, malformed reported ==="

SID="and-e1-$$"
# research AND plan both pending
cat > "$WORKFLOW_DIR/${SID}.json" <<E1_EOF
{
  "version": 1,
  "session_id": "$SID",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "pending", "updated_at": null},
    "plan":              {"status": "pending", "updated_at": null},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
E1_EOF

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: valid reason>>" && echo "<<WORKFLOW_PLAN_NOT_NEEDED>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

expect_state_step "WS-AND-E1a. research=skipped (valid part processed)" "$SID" "research" "skipped"
expect_state_step "WS-AND-E1b. plan=pending (malformed part rejected)" "$SID" "plan" "pending"

if echo "$MARK_OUT" | grep -qiE "malformed|PLAN_NOT_NEEDED"; then
    pass "WS-AND-E1c. additionalContext hints at malformed PLAN_NOT_NEEDED"
else
    fail "WS-AND-E1c. expected 'malformed'/'PLAN_NOT_NEEDED' hint, got: $MARK_OUT"
fi

echo ""
echo "=== WS-AND-E2: same sentinel twice chained — last write wins ==="

SID="and-e2-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT research "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: reason one>>" && echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: reason two>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

expect_state_step "WS-AND-E2a. research=skipped after duplicate chain" "$SID" "research" "skipped"
E2_R=$(read_state_field "$SID" "research" "skip_reason")
if [ "$E2_R" = "reason two" ]; then
    pass "WS-AND-E2b. skip_reason='reason two' (last write wins)"
else
    fail "WS-AND-E2b. expected 'reason two', got: $E2_R"
fi

# ===========================================================================
# Bug 1 — Regression guards (single sentinel, non-sentinel)
# ===========================================================================

echo ""
echo "=== WS-AND-REG-1: single sentinel without && still works ==="

SID="and-reg1-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT research "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: single file change>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

expect_state_step "WS-AND-REG-1a. research=skipped (single sentinel)" "$SID" "research" "skipped"
REG1_R=$(read_state_field "$SID" "research" "skip_reason")
if [ "$REG1_R" = "single file change" ]; then
    pass "WS-AND-REG-1b. skip_reason='single file change'"
else
    fail "WS-AND-REG-1b. expected 'single file change', got: $REG1_R"
fi

echo ""
echo "=== WS-AND-REG-2: non-sentinel command causes no state change ==="

SID="and-reg2-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT research "$SID")"

MARK_JSON=$(build_mark_json 'echo hello world' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

expect_state_step "WS-AND-REG-2a. research still=pending (no-op)" "$SID" "research" "pending"

# ===========================================================================
# Bug 2 — SKILL_MAP entries for `run_tests` and `review_security` in workflow-gate.js
# ===========================================================================

echo ""
echo "=== WS-SKILL-H1: run_tests=pending → gate blocks with actionable run_tests: hint ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="skill-h1-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT run_tests "$SID")"

echo "source" > "$REPO/app.js"
git -C "$REPO" add app.js

GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if echo "$GATE_OUT" | grep -q '"block"'; then
    pass "WS-SKILL-H1a. gate blocks when run_tests=pending"
else
    fail "WS-SKILL-H1a. expected block, got: $GATE_OUT"
fi

if echo "$GATE_OUT" | grep -q "run_tests:"; then
    pass "WS-SKILL-H1b. block reason contains 'run_tests:'"
else
    fail "WS-SKILL-H1b. expected 'run_tests:' in reason, got: $GATE_OUT"
fi

if echo "$GATE_OUT" | grep -qi "test"; then
    pass "WS-SKILL-H1c. block reason mentions 'test'"
else
    fail "WS-SKILL-H1c. expected 'test' hint, got: $GATE_OUT"
fi

echo ""
echo "=== WS-SKILL-H2: review_security=pending → gate blocks with actionable review_security: hint ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="skill-h2-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT review_security "$SID")"

echo "source" > "$REPO/app.js"
git -C "$REPO" add app.js

GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if echo "$GATE_OUT" | grep -q '"block"'; then
    pass "WS-SKILL-H2a. gate blocks when review_security=pending"
else
    fail "WS-SKILL-H2a. expected block, got: $GATE_OUT"
fi

if echo "$GATE_OUT" | grep -q "review_security:"; then
    pass "WS-SKILL-H2b. block reason contains 'review_security:'"
else
    fail "WS-SKILL-H2b. expected 'review_security:' in reason, got: $GATE_OUT"
fi

if echo "$GATE_OUT" | grep -qiE "security|review-code-security"; then
    pass "WS-SKILL-H2c. block reason mentions 'security' or 'review-code-security'"
else
    fail "WS-SKILL-H2c. expected 'security'/'review-code-security' hint, got: $GATE_OUT"
fi

echo ""
echo "=== WS-SKILL-H3: all complete (incl. run_tests+review_security) → gate approves ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="skill-h3-$$"
# All complete — use a dummy "docs" override that still says complete
OVERRIDE='{"status":"complete","updated_at":"2026-04-11T10:06:00.000Z"}'
STATE_JSON=$(build_state_with_override "$SID" "docs" "$OVERRIDE")
write_state "$SID" "$STATE_JSON"

echo "source" > "$REPO/app.js"
git -C "$REPO" add app.js

GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if echo "$GATE_OUT" | grep -q '"approve"'; then
    pass "WS-SKILL-H3. all complete → gate approves"
else
    fail "WS-SKILL-H3. expected approve, got: $GATE_OUT"
fi

echo ""
echo "=== WS-SKILL-H4: run_tests AND review_security both pending → block mentions BOTH ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="skill-h4-$$"
RUN_TESTS_OV='{"status":"pending","updated_at":null}'
REVIEW_SECURITY_OV='{"status":"pending","updated_at":null}'
STATE_JSON=$(build_state_with_multi_override "$SID" "run_tests" "$RUN_TESTS_OV" "review_security" "$REVIEW_SECURITY_OV")
write_state "$SID" "$STATE_JSON"

echo "source" > "$REPO/app.js"
git -C "$REPO" add app.js

GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if echo "$GATE_OUT" | grep -q '"block"'; then
    pass "WS-SKILL-H4a. gate blocks when run_tests+review_security both pending"
else
    fail "WS-SKILL-H4a. expected block, got: $GATE_OUT"
fi

if echo "$GATE_OUT" | grep -q "run_tests:"; then
    pass "WS-SKILL-H4b. block reason mentions 'run_tests:'"
else
    fail "WS-SKILL-H4b. expected 'run_tests:' in reason, got: $GATE_OUT"
fi

if echo "$GATE_OUT" | grep -q "review_security:"; then
    pass "WS-SKILL-H4c. block reason mentions 'review_security:'"
else
    fail "WS-SKILL-H4c. expected 'review_security:' in reason, got: $GATE_OUT"
fi

# ===========================================================================
# Results
# ===========================================================================

echo ""
echo "=== Results ==="
echo "PASSED: ${#PASSED_IDS[@]}"
echo "FAILED: ${#FAILED_IDS[@]}"
if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "Failed test IDs:"
    for id in "${FAILED_IDS[@]}"; do
        echo "  - $id"
    done
fi
echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "$ERRORS assertion(s) failed (expected pre-fix for &&-chain and SKILL_MAP tests)."
    exit 1
fi
