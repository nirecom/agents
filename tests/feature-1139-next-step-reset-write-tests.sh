#!/bin/bash
# Tests: bin/workflow/next-step
# Tags: workflow, next-step, reset, write_tests, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Real Claude Code session where the hook fires and next-step is consulted interactively
# - Actual PostToolUse hook registration and event chain
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
#
# Covers #1139 (run_tests guard) + #1133 (compaction-inconsistency recovery):
#   --reset <step> flag (R1-R3) and scoped abort hint for the
#   run_tests=complete + write_tests=pending pattern (H1-H3).

set -euo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEXT_STEP="$AGENTS_DIR/bin/workflow/next-step"

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

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  # `--` terminates option parsing so a needle starting with `-` (e.g. --reset)
  # is treated as the pattern, not a grep flag.
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

# Run next-step capturing exit code + stderr (for --reset validation cases).
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

to_node_path() {
  cygpath -m "$1" 2>/dev/null || echo "$1"
}

# State: run_tests=complete while write_tests=pending (the #1139/#1133 pattern).
# All steps up to branching_complete are complete; write_tests is current.
RUN_TESTS_COMPLETE_WRITE_TESTS_PENDING() {
  local sid="${1:-test-session}"
  cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-06-20T10:00:00.000Z",
  "closes_issues": [1139],
  "workflow_type": "wf-code",
  "steps": {
    "workflow_init":     {"status": "complete", "updated_at": "2026-06-20T10:00:30.000Z"},
    "clarify_intent":    {"status": "complete", "updated_at": "2026-06-20T10:01:00.000Z"},
    "research":          {"status": "complete", "updated_at": "2026-06-20T10:02:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-06-20T10:03:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-06-20T10:04:00.000Z"},
    "branching_complete":{"status": "complete", "updated_at": "2026-06-20T10:05:00.000Z"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_tests":      {"status": "pending",  "updated_at": null},
    "run_tests":         {"status": "complete", "updated_at": "2026-06-20T10:06:00.000Z"},
    "review_security":   {"status": "pending",  "updated_at": null},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending",  "updated_at": null},
    "cleanup":           {"status": "pending",  "updated_at": null},
    "pre_final_report_gate": {"status": "pending", "updated_at": null}
  }
}
EOF
}

# State for H2 regression guard (#1130/#1085): a DIFFERENT later-step inconsistency
# that is NOT run_tests=complete + write_tests=pending. Here review_security is
# complete while run_tests (the current step) is pending. The scoped --reset hint
# must NOT fire — the generic stale-state hint must be preserved.
REVIEW_SECURITY_COMPLETE_RUN_TESTS_PENDING() {
  local sid="${1:-test-session}"
  cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-06-20T10:00:00.000Z",
  "closes_issues": [1139],
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

# Normal state: write_tests current+pending, no later-step inconsistency.
NORMAL_WRITE_TESTS_CURRENT() {
  local sid="${1:-test-session}"
  cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-06-20T10:00:00.000Z",
  "closes_issues": [1139],
  "workflow_type": "wf-code",
  "steps": {
    "workflow_init":     {"status": "complete", "updated_at": "2026-06-20T10:00:30.000Z"},
    "clarify_intent":    {"status": "complete", "updated_at": "2026-06-20T10:01:00.000Z"},
    "research":          {"status": "complete", "updated_at": "2026-06-20T10:02:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-06-20T10:03:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-06-20T10:04:00.000Z"},
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

# ===========================================================================
# === --reset flag cases (R1-R3) ===
# ===========================================================================

echo ""
echo "=== R1: --reset run_tests with run_tests=complete → exit 0 + run_tests=pending ==="

SID="r1-$$"
write_state "$SID" "$(RUN_TESTS_COMPLETE_WRITE_TESTS_PENDING $SID)"
run_next_step_rc --session "$SID" --reset run_tests
check "R1. --reset run_tests → exit 0" "0" "$RC"
check "R1b. --reset run_tests → state shows run_tests=pending" "pending" "$(read_state_status "$SID" "run_tests")"

echo ""
echo "=== R2: --reset bogus_step (invalid step name) → nonzero exit + stderr error ==="

SID="r2-$$"
write_state "$SID" "$(RUN_TESTS_COMPLETE_WRITE_TESTS_PENDING $SID)"
run_next_step_rc --session "$SID" --reset bogus_step
check_nonzero "R2. --reset bogus_step → nonzero exit" "$RC"
if [ -n "${STDERR:-}" ]; then
  echo "PASS: R2b. --reset bogus_step → stderr error message emitted"
  PASS=$((PASS + 1))
else
  echo "FAIL: R2b. --reset bogus_step → expected stderr error message, got empty"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== R3: --reset with no step argument → nonzero exit ==="

SID="r3-$$"
write_state "$SID" "$(RUN_TESTS_COMPLETE_WRITE_TESTS_PENDING $SID)"
run_next_step_rc --session "$SID" --reset
check_nonzero "R3. --reset (no step argument) → nonzero exit" "$RC"

# ===========================================================================
# === Scoped abort hint cases (H1-H3) ===
# ===========================================================================

echo ""
echo "=== H1: run_tests=complete + write_tests=pending → abort + scoped --reset hint ==="

SID="h1-$$"
write_state "$SID" "$(RUN_TESTS_COMPLETE_WRITE_TESTS_PENDING $SID)"
REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
# No staged tests → write_tests auto-repair (#1107) does not fire → inconsistency
# scan sees run_tests (later) complete while write_tests (current) pending.

OUT=$(CLAUDE_PROJECT_DIR="$REPO_N" run_next_step --session "$SID")
ACTION=""; NEXT_HINT=""
eval "$OUT" 2>/dev/null || true

check "H1. run_tests=complete + write_tests=pending → ACTION=abort" "abort" "${ACTION:-}"
check_contains "H1b. scoped hint contains --reset run_tests" "--reset run_tests" "${NEXT_HINT:-}"
# Hint must indicate the reset is session-global / no cd needed (works from any worktree).
if echo "${NEXT_HINT:-}" | grep -qiE "session|global|any worktree|no cd|without cd"; then
  echo "PASS: H1c. scoped hint indicates session-global / no-cd-needed"
  PASS=$((PASS + 1))
else
  echo "FAIL: H1c. scoped hint should indicate session-global / no-cd-needed, got: ${NEXT_HINT:-}"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== H2: review_security=complete + run_tests=pending → generic hint, NO --reset (regression guard) ==="

SID="h2-$$"
write_state "$SID" "$(REVIEW_SECURITY_COMPLETE_RUN_TESTS_PENDING $SID)"
REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")

OUT=$(CLAUDE_PROJECT_DIR="$REPO_N" run_next_step --session "$SID")
ACTION=""; NEXT_HINT=""
eval "$OUT" 2>/dev/null || true

check "H2. review_security-complete inconsistency → ACTION=abort" "abort" "${ACTION:-}"
check_not_contains "H2b. generic inconsistency hint does NOT contain --reset (#1130/#1085 regression guard)" "--reset" "${NEXT_HINT:-}"

echo ""
echo "=== H3: normal state (write_tests current, no inconsistency) → invoke, no regression ==="

SID="h3-$$"
write_state "$SID" "$(NORMAL_WRITE_TESTS_CURRENT $SID)"
REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
# No staged tests → no auto-repair → invoke write-tests.

OUT=$(CLAUDE_PROJECT_DIR="$REPO_N" run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""; NEXT_HINT=""
eval "$OUT" 2>/dev/null || true

check "H3. normal state → ACTION=invoke" "invoke" "${ACTION:-}"
check "H3b. normal state → NEXT_SKILL=write-tests" "write-tests" "${NEXT_SKILL:-}"
check_not_contains "H3c. normal state hint does NOT contain --reset" "--reset" "${NEXT_HINT:-}"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
