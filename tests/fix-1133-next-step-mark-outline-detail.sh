#!/bin/bash
# Tests: hooks/lib/workflow-state/evidence-resolver.js, bin/workflow/next-step, bin/workflow/reconcile-state
# Tags: workflow, next-step, mark, outline, detail, auto-repair, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Real Claude Code session where PostCompact fires and next-step is consulted
# - Actual hook event chain registration
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
#
# Covers #1133 (next-step --mark CLI, outline/detail auto-repair, scoped hints):
#   --mark <step> <status> flag (M1-M6), outline/detail evidence auto-repair (A1-A2),
#   scoped abort hint when outline=pending+detail=complete (H1-H2),
#   generic hint bifurcation by hasCompletionEvidence (B1-B2),
#   reconcile-state --dry-run showing outline/detail in EVIDENCE_STEPS (G1),
#   --mark idempotency (I1), and session-ID path-traversal rejection (S1-S2).

set -euo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEXT_STEP="$AGENTS_DIR/bin/workflow/next-step"
RECONCILE="$AGENTS_DIR/bin/workflow/reconcile-state"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"

PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$PLANS_DIR"
export WORKFLOW_PLANS_DIR="$PLANS_DIR"

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

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc -- expected [$needle] in: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

check_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "FAIL: $desc -- did NOT expect [$needle] in: $haystack"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

check_nonzero() {
  local desc="$1" rc="$2"
  if [ "$rc" -ne 0 ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc -- expected nonzero exit, got 0"
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

# Run next-step for verdict output (always exits 0; KEY=value lines on stdout).
run_next_step() {
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
    run_with_timeout node "$NEXT_STEP" "$@" 2>/dev/null || true
}

# Run next-step capturing exit code + stderr.
# Sets globals: RC, STDERR.
run_next_step_rc() {
  local err_file="$TMPDIR_BASE/stderr.$RANDOM"
  set +e
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
    run_with_timeout node "$NEXT_STEP" "$@" >/dev/null 2>"$err_file"
  RC=$?
  set -e
  STDERR="$(cat "$err_file" 2>/dev/null || true)"
  rm -f "$err_file"
}

# Run reconcile-state capturing stdout.
# Sets global: RECONCILE_OUT
run_reconcile() {
  local out_file="$TMPDIR_BASE/reconcile.$RANDOM"
  set +e
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
    run_with_timeout node "$RECONCILE" "$@" >"$out_file" 2>&1
  RECONCILE_RC=$?
  set -e
  RECONCILE_OUT="$(cat "$out_file" 2>/dev/null || true)"
  rm -f "$out_file"
}

to_node_path() {
  cygpath -m "$1" 2>/dev/null || echo "$1"
}

# ---------------------------------------------------------------------------
# State fixture helpers
# ---------------------------------------------------------------------------

# outline=pending + detail=complete (compaction inconsistency).
OUTLINE_PENDING_DETAIL_COMPLETE() {
  local sid="${1:-test-session}"
  cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-06-20T10:00:00.000Z",
  "closes_issues": [1133],
  "workflow_type": "wf-code",
  "steps": {
    "workflow_init":     {"status": "complete", "updated_at": "2026-06-20T10:00:30.000Z"},
    "clarify_intent":    {"status": "complete", "updated_at": "2026-06-20T10:01:00.000Z"},
    "research":          {"status": "complete", "updated_at": "2026-06-20T10:02:00.000Z"},
    "outline":           {"status": "pending",  "updated_at": null},
    "detail":            {"status": "complete", "updated_at": "2026-06-20T10:04:00.000Z"},
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

# detail=pending + branching_complete=complete (compaction inconsistency).
DETAIL_PENDING_BRANCHING_COMPLETE() {
  local sid="${1:-test-session}"
  cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-06-20T10:00:00.000Z",
  "closes_issues": [1133],
  "workflow_type": "wf-code",
  "steps": {
    "workflow_init":     {"status": "complete", "updated_at": "2026-06-20T10:00:30.000Z"},
    "clarify_intent":    {"status": "complete", "updated_at": "2026-06-20T10:01:00.000Z"},
    "research":          {"status": "complete", "updated_at": "2026-06-20T10:02:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-06-20T10:03:00.000Z"},
    "detail":            {"status": "pending",  "updated_at": null},
    "branching_complete":{"status": "complete", "updated_at": "2026-06-20T10:05:00.000Z"},
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

# Normal: outline=complete, detail=complete, branching_complete=pending (current step).
NORMAL_BRANCHING_COMPLETE_CURRENT() {
  local sid="${1:-test-session}"
  cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-06-20T10:00:00.000Z",
  "closes_issues": [1133],
  "workflow_type": "wf-code",
  "steps": {
    "workflow_init":     {"status": "complete", "updated_at": "2026-06-20T10:00:30.000Z"},
    "clarify_intent":    {"status": "complete", "updated_at": "2026-06-20T10:01:00.000Z"},
    "research":          {"status": "complete", "updated_at": "2026-06-20T10:02:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-06-20T10:03:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-06-20T10:04:00.000Z"},
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

# Anomalous: review_security=complete + run_tests=pending (B1/B2 generic hint target).
REVIEW_SECURITY_COMPLETE_RUN_TESTS_PENDING() {
  local sid="${1:-test-session}"
  cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-06-20T10:00:00.000Z",
  "closes_issues": [1133],
  "workflow_type": "wf-code",
  "steps": {
    "workflow_init":     {"status": "complete", "updated_at": "2026-06-20T10:00:30.000Z"},
    "clarify_intent":    {"status": "complete", "updated_at": "2026-06-20T10:01:00.000Z"},
    "research":          {"status": "complete", "updated_at": "2026-06-20T10:02:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-06-20T10:03:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-06-20T10:04:00.000Z"},
    "branching_complete":{"status": "complete", "updated_at": "2026-06-20T10:05:00.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-06-20T10:06:00.000Z"},
    "review_tests":      {"status": "complete", "updated_at": "2026-06-20T10:06:30.000Z"},
    "run_tests":         {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "complete", "updated_at": "2026-06-20T10:07:00.000Z"},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending",  "updated_at": null},
    "cleanup":           {"status": "pending",  "updated_at": null},
    "pre_final_report_gate": {"status": "pending", "updated_at": null}
  }
}
EOF
}

setup_repo() {
  local repo="$TMPDIR_BASE/repo-$RANDOM"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config core.hooksPath /dev/null
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q --no-verify -m "initial"
  echo "$repo"
}

# ---------------------------------------------------------------------------
# Source test sections
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_DIR="$SCRIPT_DIR/fix-1133-next-step-mark-outline-detail"

# shellcheck source=/dev/null
. "$SUB_DIR/mark.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/idempotency-security.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/auto-repair.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/hint.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/reconcile.sh"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
