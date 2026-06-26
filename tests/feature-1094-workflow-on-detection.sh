#!/bin/bash
# Tests: hooks/workflow-mark/enforce-override-handlers.js
# Tags: L2, workflow, mark, enforce-override, reconcile, scope:issue-specific

# L3 gap (what this test does NOT catch):
# - real hook PostToolUse event in live claude session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -euo pipefail

[ -f "hooks/lib/workflow-state/evidence-resolver.js" ] || { echo "SKIP: evidence-resolver.js not yet implemented (WORKFLOW_ON detection not yet implemented)"; exit 0; }

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARK_HOOK="$AGENTS_DIR/hooks/workflow-mark.js"

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

run_mark() {
  local json="$1"
  echo "$json" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
    run_with_timeout node "$MARK_HOOK" 2>/dev/null || true
}

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

build_workflow_on_json() {
  local sid="$1"
  printf '{"tool_name":"Bash","tool_input":{"command":"echo \\"<<WORKFLOW_ENFORCE_WORKFLOW_ON: done>>\\""},"tool_response":{"exit_code":0,"stdout":"<<WORKFLOW_ENFORCE_WORKFLOW_ON: done>>","stderr":""},"session_id":"%s"}' "$sid"
}

echo ""
echo "=== WOD-1: clarify_intent=pending + intent.md present → pushMessage contains reconcile-state ==="

SID="wod1-$$"
write_state "$SID" "$(CI_PENDING_STATE $SID)"
touch "$PLANS_DIR/${SID}-intent.md"

MARK_JSON=$(build_workflow_on_json "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

check_contains "WOD-1. clarify_intent pending + intent.md present → reconcile-state warning" "reconcile-state" "$MARK_OUT"

echo ""
echo "=== WOD-2: clarify_intent=pending + intent.md absent → no reconcile-state warning ==="

SID="wod2-$$"
write_state "$SID" "$(CI_PENDING_STATE $SID)"
# No intent.md

MARK_JSON=$(build_workflow_on_json "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

check_not_contains "WOD-2. clarify_intent pending + no intent.md → no reconcile-state warning" "reconcile-state" "$MARK_OUT"

echo ""
echo "=== WOD-3: repoDir resolution failure → fail-open (no error output) ==="

SID="wod3-$$"
write_state "$SID" "$(CI_PENDING_STATE $SID)"
# Trigger resolution failure with a non-git dir
MARK_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"echo \\"<<WORKFLOW_ENFORCE_WORKFLOW_ON: done>>\\"","cwd":"/nonexistent/dir/$$"},"tool_response":{"exit_code":0,"stdout":"<<WORKFLOW_ENFORCE_WORKFLOW_ON: done>>","stderr":""},"session_id":"%s"}' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

# Should not produce an error/exception
if echo "$MARK_OUT" | grep -qi "error\|exception\|throw"; then
  echo "FAIL: WOD-3. repoDir failure should be fail-open, but got error: $MARK_OUT"
  FAIL=$((FAIL + 1))
else
  echo "PASS: WOD-3. repoDir resolution failure is fail-open (no exception)"
  PASS=$((PASS + 1))
fi

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
