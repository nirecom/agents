#!/bin/bash
# Tests: bin/workflow/reconcile-state
# Tags: L2, workflow, reconcile, evidence, scope:issue-specific

# L3 gap (what this test does NOT catch):
# - real hook PreToolUse event in live claude session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -euo pipefail

[ -f "bin/workflow/reconcile-state" ] || { echo "SKIP: reconcile-state not yet implemented"; exit 0; }

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECONCILE="$AGENTS_DIR/bin/workflow/reconcile-state"

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

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc -- expected [$expected] got [$actual]"
    FAIL=$((FAIL + 1))
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

run_reconcile() {
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
    run_with_timeout node "$RECONCILE" "$@" 2>/dev/null || true
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

echo ""
echo "=== RS-1: --dry-run: state unchanged even with intent.md present ==="

SID="rs1-$$"
write_state "$SID" "$(CI_PENDING_STATE $SID)"
touch "$PLANS_DIR/${SID}-intent.md"

run_reconcile --session "$SID" --dry-run

ACTUAL=$(read_state_status "$SID" "clarify_intent")
check "RS-1. --dry-run: clarify_intent remains pending" "pending" "$ACTUAL"

echo ""
echo "=== RS-2: intent.md present + clarify_intent=pending → repaired to complete ==="

SID="rs2-$$"
write_state "$SID" "$(CI_PENDING_STATE $SID)"
touch "$PLANS_DIR/${SID}-intent.md"

run_reconcile --session "$SID"

ACTUAL=$(read_state_status "$SID" "clarify_intent")
check "RS-2. intent.md present → clarify_intent=complete after reconcile" "complete" "$ACTUAL"

echo ""
echo "=== RS-3: no intent.md → clarify_intent stays pending ==="

SID="rs3-$$"
write_state "$SID" "$(CI_PENDING_STATE $SID)"
# Do NOT create intent.md

run_reconcile --session "$SID"

ACTUAL=$(read_state_status "$SID" "clarify_intent")
check "RS-3. no intent.md → clarify_intent remains pending" "pending" "$ACTUAL"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
