#!/bin/bash
# Tests: hooks/workflow-gate.js
# Tags: L2, workflow, gate, evidence, clarify-intent, scope:issue-specific

# L3 gap (what this test does NOT catch):
# - real hook PreToolUse event in live claude session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -euo pipefail

[ -f "hooks/lib/workflow-state/evidence-resolver.js" ] || { echo "SKIP: evidence-resolver.js not yet implemented (clarify_intent gate not yet evidence-aware)"; exit 0; }

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE_HOOK="$AGENTS_DIR/hooks/workflow-gate.js"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"

PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$PLANS_DIR"

PASS=0
FAIL=0

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc -- expected [$needle] in: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

check_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "FAIL: $desc -- did NOT expect [$needle] in: $haystack"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

write_state() {
  local sid="$1" json="$2"
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

run_gate() {
  local json="$1"
  echo "$json" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" run_with_timeout node "$GATE_HOOK" 2>/dev/null
}

# State with workflow_init=complete, clarify_intent=pending
CI_PENDING_STATE() {
  local sid="${1:-test-session}"
  cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-04-11T10:00:00.000Z",
  "closes_issues": [1094],
  "steps": {
    "workflow_init":     {"status": "complete", "updated_at": "2026-04-11T10:00:30.000Z"},
    "clarify_intent":    {"status": "pending",  "updated_at": null},
    "research":          {"status": "pending",  "updated_at": null},
    "outline":           {"status": "pending",  "updated_at": null},
    "detail":            {"status": "pending",  "updated_at": null},
    "branching_complete":{"status": "pending",  "updated_at": null},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_tests":      {"status": "pending",  "updated_at": null},
    "run_tests":         {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "pending",  "updated_at": null},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending",  "updated_at": null},
    "cleanup":           {"status": "pending",  "updated_at": null},
    "pre_final_report_gate": {"status": "pending", "updated_at": null}
  }
}
EOF
}

# State with both workflow_init and clarify_intent complete
CI_COMPLETE_STATE() {
  local sid="${1:-test-session}"
  cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-04-11T10:00:00.000Z",
  "closes_issues": [1094],
  "steps": {
    "workflow_init":     {"status": "complete", "updated_at": "2026-04-11T10:00:30.000Z"},
    "clarify_intent":    {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "research":          {"status": "pending",  "updated_at": null},
    "outline":           {"status": "pending",  "updated_at": null},
    "detail":            {"status": "pending",  "updated_at": null},
    "branching_complete":{"status": "pending",  "updated_at": null},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_tests":      {"status": "pending",  "updated_at": null},
    "run_tests":         {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "pending",  "updated_at": null},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending",  "updated_at": null},
    "cleanup":           {"status": "pending",  "updated_at": null},
    "pre_final_report_gate": {"status": "pending", "updated_at": null}
  }
}
EOF
}

echo ""
echo "=== WGE-1: intent.md present + clarify_intent=pending → gate passes (auto-repair) ==="

SID="wge1-$$"
write_state "$SID" "$(CI_PENDING_STATE $SID)"
touch "$PLANS_DIR/${SID}-intent.md"

GATE_INPUT=$(printf '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.txt","content":"x"},"session_id":"%s"}' "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if echo "$GATE_OUT" | grep -q '"approve"' || ! echo "$GATE_OUT" | grep -q 'clarify_intent'; then
  echo "PASS: WGE-1. intent.md present + clarify_intent=pending → gate does not block on clarify_intent"
  PASS=$((PASS + 1))
else
  echo "FAIL: WGE-1. expected gate to pass or not mention clarify_intent, got: $GATE_OUT"
  FAIL=$((FAIL + 1))
fi

# After auto-repair, state should be complete
ACTUAL=$(read_state_status "$SID" "clarify_intent")
if [ "$ACTUAL" = "complete" ]; then
  echo "PASS: WGE-1b. clarify_intent auto-repaired to complete"
  PASS=$((PASS + 1))
else
  echo "FAIL: WGE-1b. expected clarify_intent=complete after auto-repair, got: $ACTUAL"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== WGE-2: intent.md absent + clarify_intent=pending → gate blocks ==="

SID="wge2-$$"
write_state "$SID" "$(CI_PENDING_STATE $SID)"
# Do NOT create intent.md

GATE_INPUT=$(printf '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.txt","content":"x"},"session_id":"%s"}' "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

check_contains "WGE-2. no intent.md + clarify_intent=pending → block" "clarify_intent" "$GATE_OUT"
check_contains "WGE-2b. block message mentions clarify-intent skill" "clarify-intent" "$GATE_OUT"

echo ""
echo "=== WGE-3: intent.md present + clarify_intent=complete → gate passes (no state change) ==="

SID="wge3-$$"
write_state "$SID" "$(CI_COMPLETE_STATE $SID)"
touch "$PLANS_DIR/${SID}-intent.md"

GATE_INPUT=$(printf '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.txt","content":"x"},"session_id":"%s"}' "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if ! echo "$GATE_OUT" | grep -q '"block"'; then
  echo "PASS: WGE-3. clarify_intent=complete → gate passes"
  PASS=$((PASS + 1))
else
  echo "FAIL: WGE-3. expected gate to pass when clarify_intent=complete, got: $GATE_OUT"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
