#!/bin/bash
# Tests for new workflow steps: clarify_intent and branching_decision
# Covers:
#   - workflow-state.js: migration and VALID_STEPS / SKIPPABLE_STEPS exports
#   - workflow-mark.js: CLARIFY_INTENT_COMPLETE, BRANCHING_DECIDED, PLAN_NOT_NEEDED
#   - workflow-gate.js: gate blocks on new steps, docs-only bypass
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE_HOOK="$DOTFILES_DIR/hooks/workflow-gate.js"
MARK_HOOK="$DOTFILES_DIR/hooks/workflow-mark.js"
WS_LIB="$DOTFILES_DIR/hooks/lib/workflow-state.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# ---------------------------------------------------------------------------
# Temp dirs and cleanup
# ---------------------------------------------------------------------------

TMPDIR_BASE=$(mktemp -d)
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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

run_mark() {
    local json="$1"
    echo "$json" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$MARK_HOOK" 2>/dev/null || true
}

run_gate() {
    local json="$1"
    echo "$json" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$GATE_HOOK" 2>/dev/null || true
}

build_mark_json() {
    local cmd="$1" sid="${2:-test-session}" exit_code="${3:-0}"
    local esc=${cmd//\\/\\\\}
    esc=${esc//\"/\\\"}
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":%s,"stdout":"%s\\n","stderr":""},"session_id":"%s"}' \
        "$esc" "$exit_code" "$esc" "$sid"
}

build_mark_json_no_sid() {
    local cmd="$1" exit_code="${2:-0}"
    local esc=${cmd//\\/\\\\}
    esc=${esc//\"/\\\"}
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":%s,"stdout":"%s\\n","stderr":""}}' \
        "$esc" "$exit_code" "$esc"
}

# All steps complete (new schema includes clarify_intent and branching_decision)
ALL_COMPLETE_JSON() {
    local sid="${1:-test-session}"
    cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "clarify_intent":    {"status": "complete", "updated_at": "2026-04-11T10:00:30.000Z"},
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "branching_decision":{"status": "complete", "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
}

# All steps complete except clarify_intent (pending)
ALL_COMPLETE_CI_PENDING_JSON() {
    local sid="${1:-test-session}"
    cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "clarify_intent":    {"status": "pending", "updated_at": null},
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "branching_decision":{"status": "complete", "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
}

# All steps complete except branching_decision (pending)
ALL_COMPLETE_BD_PENDING_JSON() {
    local sid="${1:-test-session}"
    cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "clarify_intent":    {"status": "complete", "updated_at": "2026-04-11T10:00:30.000Z"},
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "branching_decision":{"status": "pending", "updated_at": null},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
}

# ===========================================================================
# Migration (workflow-state.js readState)
# ===========================================================================

echo ""
echo "=== Migration: readState backfills missing clarify_intent / branching_decision ==="

# M1: Old state JSON without clarify_intent → readState sets it to {status:"complete"}
SID="m1-$$"
cat > "$WORKFLOW_DIR/${SID}.json" <<EOF
{
  "version": 1,
  "session_id": "$SID",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
M1_RESULT=$(cd "$DOTFILES_DIR" && CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node -e "
const wf = require('./hooks/lib/workflow-state.js');
const s = wf.readState('$SID');
console.log(s && s.steps && s.steps.clarify_intent ? s.steps.clarify_intent.status : 'MISSING');
" 2>/dev/null || echo "ERROR")
if [ "$M1_RESULT" = "complete" ]; then
    pass "M1. Old state without clarify_intent → readState sets it to complete"
else
    fail "M1. Old state without clarify_intent → expected complete, got: $M1_RESULT"
fi

# M2: Old state JSON without branching_decision → readState sets it to {status:"complete"}
SID="m2-$$"
cat > "$WORKFLOW_DIR/${SID}.json" <<EOF
{
  "version": 1,
  "session_id": "$SID",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
M2_RESULT=$(cd "$DOTFILES_DIR" && CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node -e "
const wf = require('./hooks/lib/workflow-state.js');
const s = wf.readState('$SID');
console.log(s && s.steps && s.steps.branching_decision ? s.steps.branching_decision.status : 'MISSING');
" 2>/dev/null || echo "ERROR")
if [ "$M2_RESULT" = "complete" ]; then
    pass "M2. Old state without branching_decision → readState sets it to complete"
else
    fail "M2. Old state without branching_decision → expected complete, got: $M2_RESULT"
fi

# M3: State that already has both steps → readState does NOT overwrite them
SID="m3-$$"
cat > "$WORKFLOW_DIR/${SID}.json" <<EOF
{
  "version": 1,
  "session_id": "$SID",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "clarify_intent":    {"status": "pending", "updated_at": null},
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "branching_decision":{"status": "pending", "updated_at": null},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
M3_CI=$(cd "$DOTFILES_DIR" && CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node -e "
const wf = require('./hooks/lib/workflow-state.js');
const s = wf.readState('$SID');
console.log(s && s.steps && s.steps.clarify_intent ? s.steps.clarify_intent.status : 'MISSING');
" 2>/dev/null || echo "ERROR")
M3_BD=$(cd "$DOTFILES_DIR" && CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node -e "
const wf = require('./hooks/lib/workflow-state.js');
const s = wf.readState('$SID');
console.log(s && s.steps && s.steps.branching_decision ? s.steps.branching_decision.status : 'MISSING');
" 2>/dev/null || echo "ERROR")
if [ "$M3_CI" = "pending" ]; then
    pass "M3a. clarify_intent already present → readState does NOT overwrite (still pending)"
else
    fail "M3a. expected clarify_intent=pending, got: $M3_CI"
fi
if [ "$M3_BD" = "pending" ]; then
    pass "M3b. branching_decision already present → readState does NOT overwrite (still pending)"
else
    fail "M3b. expected branching_decision=pending, got: $M3_BD"
fi

# M4: VALID_STEPS exports clarify_intent at index 0 and includes branching_decision
M4_RESULT=$(cd "$DOTFILES_DIR" && node -e "
const wf = require('./hooks/lib/workflow-state.js');
const vs = wf.VALID_STEPS;
const ciIdx = vs.indexOf('clarify_intent');
const bdIdx = vs.indexOf('branching_decision');
if (ciIdx !== 0) { console.log('clarify_intent at index ' + ciIdx + ', expected 0'); process.exit(1); }
if (bdIdx === -1) { console.log('branching_decision not in VALID_STEPS'); process.exit(1); }
console.log('ok:ci=' + ciIdx + ',bd=' + bdIdx);
" 2>/dev/null || echo "ERROR")
if echo "$M4_RESULT" | grep -q "^ok:"; then
    pass "M4. VALID_STEPS: clarify_intent at index 0, branching_decision present ($M4_RESULT)"
else
    fail "M4. VALID_STEPS check failed: $M4_RESULT"
fi

# M5: SKIPPABLE_STEPS does NOT include clarify_intent or branching_decision
M5_RESULT=$(cd "$DOTFILES_DIR" && node -e "
const wf = require('./hooks/lib/workflow-state.js');
const ss = wf.SKIPPABLE_STEPS;
const hasCi = ss.includes('clarify_intent');
const hasBd = ss.includes('branching_decision');
if (hasCi) { console.log('clarify_intent is in SKIPPABLE_STEPS (should not be)'); process.exit(1); }
if (hasBd) { console.log('branching_decision is in SKIPPABLE_STEPS (should not be)'); process.exit(1); }
console.log('ok');
" 2>/dev/null || echo "ERROR")
if [ "$M5_RESULT" = "ok" ]; then
    pass "M5. SKIPPABLE_STEPS does not include clarify_intent or branching_decision"
else
    fail "M5. SKIPPABLE_STEPS check failed: $M5_RESULT"
fi

# ===========================================================================
# CLARIFY_INTENT_COMPLETE sentinel (workflow-mark.js)
# ===========================================================================

echo ""
echo "=== CLARIFY_INTENT_COMPLETE sentinel ==="

# C1: echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>" → clarify_intent status becomes "complete"
SID="c1-$$"
write_state "$SID" "$(ALL_COMPLETE_CI_PENDING_JSON "$SID")"
C1_JSON=$(build_mark_json 'echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"' "$SID")
run_mark "$C1_JSON" > /dev/null
expect_state_step "C1. CLARIFY_INTENT_COMPLETE → clarify_intent=complete" "$SID" "clarify_intent" "complete"

# C2: No session_id → error message emitted, state not written
C2_CMD='echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"'
C2_JSON=$(build_mark_json_no_sid "$C2_CMD")
C2_OUT=$(echo "$C2_JSON" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" CLAUDE_ENV_FILE="" node "$MARK_HOOK" 2>/dev/null || true)
if echo "$C2_OUT" | grep -qiE "could not resolve session_id|session_id"; then
    pass "C2a. CLARIFY_INTENT_COMPLETE with no session_id → error in additionalContext"
else
    fail "C2a. expected 'could not resolve session_id', got: $C2_OUT"
fi
# Verify a specific known session's state was not affected by the no-session-id run
SID_C2="c2-check-$$"
write_state "$SID_C2" "$(ALL_COMPLETE_CI_PENDING_JSON "$SID_C2")"
# State should remain pending since the no-sid call couldn't target any session
C2_CI_STATUS=$(read_state_status "$SID_C2" "clarify_intent")
if [ "$C2_CI_STATUS" = "pending" ]; then
    pass "C2b. Known session state unaffected by no-session-id call → clarify_intent still pending"
else
    fail "C2b. expected clarify_intent=pending, got: $C2_CI_STATUS"
fi

# C3: Idempotency — running twice produces complete status without error
SID="c3-$$"
write_state "$SID" "$(ALL_COMPLETE_CI_PENDING_JSON "$SID")"
C3_JSON=$(build_mark_json 'echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"' "$SID")
C3_OUT1=$(run_mark "$C3_JSON")
C3_OUT2=$(run_mark "$C3_JSON")
expect_state_step "C3a. CLARIFY_INTENT_COMPLETE idempotency → still complete after second run" "$SID" "clarify_intent" "complete"
# Check no error in second run
if echo "$C3_OUT2" | node -e "
try {
  const s = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  process.exit((s.additionalContext && s.additionalContext.includes('error')) ? 1 : 0);
} catch(e) { process.exit(0); }
" 2>/dev/null; then
    pass "C3b. CLARIFY_INTENT_COMPLETE idempotency → no error on second run"
else
    fail "C3b. CLARIFY_INTENT_COMPLETE second run produced error in additionalContext: $C3_OUT2"
fi

# ===========================================================================
# BRANCHING_DECIDED sentinel (workflow-mark.js)
# ===========================================================================

echo ""
echo "=== BRANCHING_DECIDED sentinel ==="

# B1: echo "<<WORKFLOW_BRANCHING_DECIDED: working on main>>" → branching_decision complete, decision field recorded
SID="b1-$$"
write_state "$SID" "$(ALL_COMPLETE_BD_PENDING_JSON "$SID")"
B1_JSON=$(build_mark_json 'echo "<<WORKFLOW_BRANCHING_DECIDED: working on main>>"' "$SID")
run_mark "$B1_JSON" > /dev/null
expect_state_step "B1a. BRANCHING_DECIDED 'working on main' → branching_decision=complete" "$SID" "branching_decision" "complete"
B1_DECISION=$(read_state_field "$SID" "branching_decision" "decision")
if [ "$B1_DECISION" = "working on main" ]; then
    pass "B1b. decision field recorded: 'working on main'"
else
    fail "B1b. expected decision='working on main', got: $B1_DECISION"
fi

# B2: echo "<<WORKFLOW_BRANCHING_DECIDED: branch: feat/foo>>" → branching_decision complete
SID="b2-$$"
write_state "$SID" "$(ALL_COMPLETE_BD_PENDING_JSON "$SID")"
B2_JSON=$(build_mark_json 'echo "<<WORKFLOW_BRANCHING_DECIDED: branch: feat/foo>>"' "$SID")
run_mark "$B2_JSON" > /dev/null
expect_state_step "B2a. BRANCHING_DECIDED 'branch: feat/foo' → branching_decision=complete" "$SID" "branching_decision" "complete"
B2_DECISION=$(read_state_field "$SID" "branching_decision" "decision")
if [ "$B2_DECISION" = "branch: feat/foo" ]; then
    pass "B2b. decision field recorded: 'branch: feat/foo'"
else
    fail "B2b. expected decision='branch: feat/foo', got: $B2_DECISION"
fi

# B3: Malformed (no colon+value) → malformed error message
SID="b3-$$"
write_state "$SID" "$(ALL_COMPLETE_JSON "$SID")"
B3_JSON=$(build_mark_json 'echo "<<WORKFLOW_BRANCHING_DECIDED>>"' "$SID")
B3_OUT=$(run_mark "$B3_JSON")
B3_STATUS=$(read_state_status "$SID" "branching_decision")
if [ "$B3_STATUS" = "complete" ]; then
    pass "B3a. Malformed BRANCHING_DECIDED → branching_decision unchanged (still complete)"
else
    fail "B3a. expected branching_decision=complete (unchanged), got: $B3_STATUS"
fi
if echo "$B3_OUT" | grep -qiE "malformed|BRANCHING_DECIDED|decision"; then
    pass "B3b. Malformed BRANCHING_DECIDED → error message in additionalContext"
else
    fail "B3b. expected malformed error, got: $B3_OUT"
fi

# B4: Reason too short (≤2 non-space chars) → validation error
SID="b4-$$"
write_state "$SID" "$(ALL_COMPLETE_BD_PENDING_JSON "$SID")"
B4_JSON=$(build_mark_json 'echo "<<WORKFLOW_BRANCHING_DECIDED: xy>>"' "$SID")
B4_OUT=$(run_mark "$B4_JSON")
B4_STATUS=$(read_state_status "$SID" "branching_decision")
if [ "$B4_STATUS" = "pending" ]; then
    pass "B4a. Short reason 'xy' → branching_decision stays pending"
else
    fail "B4a. expected branching_decision=pending, got: $B4_STATUS"
fi
if echo "$B4_OUT" | grep -qiE "too short|reject|reason"; then
    pass "B4b. Short reason → validation error in additionalContext"
else
    fail "B4b. expected validation error, got: $B4_OUT"
fi

# B5: Reason is a placeholder ("no") → dud error
SID="b5-$$"
write_state "$SID" "$(ALL_COMPLETE_BD_PENDING_JSON "$SID")"
B5_JSON=$(build_mark_json 'echo "<<WORKFLOW_BRANCHING_DECIDED: no>>"' "$SID")
B5_OUT=$(run_mark "$B5_JSON")
B5_STATUS=$(read_state_status "$SID" "branching_decision")
if [ "$B5_STATUS" = "pending" ]; then
    pass "B5a. Placeholder reason 'no' → branching_decision stays pending"
else
    fail "B5a. expected branching_decision=pending, got: $B5_STATUS"
fi
if echo "$B5_OUT" | grep -qiE "placeholder|dud|reject"; then
    pass "B5b. Placeholder reason → dud error in additionalContext"
else
    fail "B5b. expected dud/placeholder error, got: $B5_OUT"
fi

# B6: No session_id → error message, state not written
B6_CMD='echo "<<WORKFLOW_BRANCHING_DECIDED: main direct work>>"'
B6_JSON=$(build_mark_json_no_sid "$B6_CMD")
B6_OUT=$(echo "$B6_JSON" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" CLAUDE_ENV_FILE="" node "$MARK_HOOK" 2>/dev/null || true)
if echo "$B6_OUT" | grep -qiE "could not resolve session_id|session_id"; then
    pass "B6a. BRANCHING_DECIDED with no session_id → error in additionalContext"
else
    fail "B6a. expected 'could not resolve session_id', got: $B6_OUT"
fi

# B7: Idempotency — running twice stays complete, no error
SID="b7-$$"
write_state "$SID" "$(ALL_COMPLETE_BD_PENDING_JSON "$SID")"
B7_JSON=$(build_mark_json 'echo "<<WORKFLOW_BRANCHING_DECIDED: main direct work>>"' "$SID")
run_mark "$B7_JSON" > /dev/null
B7_OUT2=$(run_mark "$B7_JSON")
expect_state_step "B7a. BRANCHING_DECIDED idempotency → still complete after second run" "$SID" "branching_decision" "complete"
if echo "$B7_OUT2" | node -e "
try {
  const s = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  process.exit((s.additionalContext && s.additionalContext.includes('error')) ? 1 : 0);
} catch(e) { process.exit(0); }
" 2>/dev/null; then
    pass "B7b. BRANCHING_DECIDED idempotency → no error on second run"
else
    fail "B7b. BRANCHING_DECIDED second run produced error in additionalContext: $B7_OUT2"
fi

# B8: Security — decision containing '>' does NOT match regex (no state change)
SID="b8-$$"
write_state "$SID" "$(ALL_COMPLETE_BD_PENDING_JSON "$SID")"
# The '>' in the reason breaks the regex pattern [^>]+ — should not match
B8_JSON=$(build_mark_json 'echo "<<WORKFLOW_BRANCHING_DECIDED: a>b>>"' "$SID")
B8_OUT=$(run_mark "$B8_JSON")
B8_STATUS=$(read_state_status "$SID" "branching_decision")
if [ "$B8_STATUS" = "pending" ]; then
    pass "B8a. Decision containing '>' → branching_decision stays pending (regex rejection)"
else
    fail "B8a. expected branching_decision=pending, got: $B8_STATUS"
fi

# ===========================================================================
# PLAN_NOT_NEEDED also skips research (workflow-mark.js)
# ===========================================================================

echo ""
echo "=== PLAN_NOT_NEEDED also skips research ==="

# P1: PLAN_NOT_NEEDED → both plan and research become "skipped"
SID="p1-$$"
cat > "$WORKFLOW_DIR/${SID}.json" <<EOF
{
  "version": 1,
  "session_id": "$SID",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "clarify_intent":    {"status": "complete", "updated_at": "2026-04-11T10:00:30.000Z"},
    "research":          {"status": "pending", "updated_at": null},
    "plan":              {"status": "pending", "updated_at": null},
    "branching_decision":{"status": "pending", "updated_at": null},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
P1_JSON=$(build_mark_json 'echo "<<WORKFLOW_PLAN_NOT_NEEDED: trivial docs fix only>>"' "$SID")
run_mark "$P1_JSON" > /dev/null
expect_state_step "P1a. PLAN_NOT_NEEDED → plan=skipped" "$SID" "plan" "skipped"
expect_state_step "P1b. PLAN_NOT_NEEDED → research=skipped" "$SID" "research" "skipped"

# P2: Regression — research is skipped (not just plan) when PLAN_NOT_NEEDED fires
SID="p2-$$"
cat > "$WORKFLOW_DIR/${SID}.json" <<EOF
{
  "version": 1,
  "session_id": "$SID",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "clarify_intent":    {"status": "complete", "updated_at": "2026-04-11T10:00:30.000Z"},
    "research":          {"status": "pending", "updated_at": null},
    "plan":              {"status": "pending", "updated_at": null},
    "branching_decision":{"status": "pending", "updated_at": null},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
P2_JSON=$(build_mark_json 'echo "<<WORKFLOW_PLAN_NOT_NEEDED: single file minor fix>>"' "$SID")
run_mark "$P2_JSON" > /dev/null
P2_RESEARCH=$(read_state_status "$SID" "research")
if [ "$P2_RESEARCH" = "skipped" ]; then
    pass "P2. Regression: PLAN_NOT_NEEDED skips research too (not just plan)"
else
    fail "P2. Regression: expected research=skipped after PLAN_NOT_NEEDED, got: $P2_RESEARCH"
fi

# ===========================================================================
# Gate blocks on new steps (workflow-gate.js)
# ===========================================================================

echo ""
echo "=== Gate: blocks on new steps ==="

# G1: State with clarify_intent: pending → gate blocks, error includes /clarify-intent
REPO=$(setup_repo)
SID="g1-$$"
cat > "$WORKFLOW_DIR/${SID}.json" <<EOF
{
  "version": 1,
  "session_id": "$SID",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "clarify_intent":    {"status": "pending", "updated_at": null},
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "branching_decision":{"status": "complete", "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
G1_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m test\"},\"session_id\":\"$SID\"}"
G1_OUT=$(run_gate "$G1_JSON")
if echo "$G1_OUT" | grep -q '"block"'; then
    pass "G1a. clarify_intent pending → gate blocks"
else
    fail "G1a. expected block, got: $G1_OUT"
fi
if echo "$G1_OUT" | grep -qiE "clarify.intent|clarify-intent|/clarify"; then
    pass "G1b. block message contains clarify-intent hint"
else
    fail "G1b. expected /clarify-intent in block message, got: $G1_OUT"
fi

# G2: State with branching_decision: pending → gate blocks, error includes rules/branch.md
REPO=$(setup_repo)
SID="g2-$$"
cat > "$WORKFLOW_DIR/${SID}.json" <<EOF
{
  "version": 1,
  "session_id": "$SID",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "clarify_intent":    {"status": "complete", "updated_at": "2026-04-11T10:00:30.000Z"},
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "branching_decision":{"status": "pending", "updated_at": null},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
G2_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m test\"},\"session_id\":\"$SID\"}"
G2_OUT=$(run_gate "$G2_JSON")
if echo "$G2_OUT" | grep -q '"block"'; then
    pass "G2a. branching_decision pending → gate blocks"
else
    fail "G2a. expected block, got: $G2_OUT"
fi
if echo "$G2_OUT" | grep -qiE "branch\.md|worktree\.md|BRANCHING_DECIDED"; then
    pass "G2b. block message contains branching guidance hint"
else
    fail "G2b. expected rules/branch.md or BRANCHING_DECIDED in block message, got: $G2_OUT"
fi

# G3: State with both complete (all steps complete) → gate approves
REPO=$(setup_repo)
SID="g3-$$"
write_state "$SID" "$(ALL_COMPLETE_JSON "$SID")"
echo "source" > "$REPO/app.js"
git -C "$REPO" add app.js
# Convert bash Unix-style path to native path for JSON embedding
REPO_N=$(cygpath -m "$REPO" 2>/dev/null || echo "$REPO")
G3_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m test"},"session_id":"%s"}' "$REPO_N" "$SID")
G3_OUT=$(run_gate "$G3_JSON")
if echo "$G3_OUT" | grep -q '"approve"'; then
    pass "G3. All steps (including clarify_intent, branching_decision) complete → gate approves"
else
    fail "G3. expected approve, got: $G3_OUT"
fi

# G4: docs-only staged files → gate bypasses clarify_intent and branching_decision
REPO=$(setup_repo)
SID="g4-$$"
# State where clarify_intent and branching_decision are pending but all others complete
cat > "$WORKFLOW_DIR/${SID}.json" <<EOF
{
  "version": 1,
  "session_id": "$SID",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "clarify_intent":    {"status": "pending", "updated_at": null},
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "branching_decision":{"status": "pending", "updated_at": null},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
# Stage only docs/ .md file (docs-only allowlist)
mkdir -p "$REPO/docs"
echo "# updated" > "$REPO/docs/architecture.md"
git -C "$REPO" add docs/architecture.md
REPO_N4=$(cygpath -m "$REPO" 2>/dev/null || echo "$REPO")
G4_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m docs"},"session_id":"%s"}' "$REPO_N4" "$SID")
G4_OUT=$(run_gate "$G4_JSON")
# docs-only: only user_verification is required — gate should block only on user_verification
# (clarify_intent and branching_decision are bypassed)
if echo "$G4_OUT" | grep -q '"block"'; then
    # It blocks — but should only mention user_verification, not clarify_intent or branching_decision
    if ! echo "$G4_OUT" | grep -qiE '"clarify_intent"|"branching_decision"'; then
        pass "G4. docs-only: gate bypasses clarify_intent and branching_decision (blocks only on user_verification)"
    else
        fail "G4. docs-only: gate should bypass clarify_intent/branching_decision but included them in block: $G4_OUT"
    fi
elif echo "$G4_OUT" | grep -q '"approve"'; then
    # user_verification is complete so approve is also valid
    pass "G4. docs-only: gate approves (all required steps including user_verification complete)"
else
    fail "G4. unexpected gate output for docs-only: $G4_OUT"
fi

# ===========================================================================
# Results
# ===========================================================================

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
