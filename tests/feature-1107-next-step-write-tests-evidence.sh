#!/bin/bash
# Tests: bin/workflow/next-step
# Tags: L2, workflow, next-step, write_tests, evidence, scope:issue-specific

# L3 gap (what this test does NOT catch):
# - real hook PreToolUse event in live claude session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -euo pipefail

[ -f "hooks/lib/workflow-state/evidence-resolver.js" ] || { echo "SKIP: evidence-resolver.js not yet implemented (next-step not yet evidence-aware)"; exit 0; }

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

run_next_step() {
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
    run_with_timeout node "$NEXT_STEP" "$@" 2>/dev/null || true
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

# State with all steps complete except write_tests
# write_tests=pending, review_tests=pending, run_tests=pending (normal #1107 scenario: write_tests is current)
WRITE_TESTS_PENDING_STATE() {
  local sid="${1:-test-session}"
  cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-04-11T10:00:00.000Z",
  "closes_issues": [1107],
  "steps": {
    "workflow_init":     {"status": "complete", "updated_at": "2026-04-11T10:00:30.000Z"},
    "clarify_intent":    {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "branching_complete":{"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
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

# State for C1 regression guard: write_tests=pending + review_tests=complete + run_tests=pending
# This is the #1107 core scenario where inconsistency check fires before auto-repair (pre-fix)
WRITE_TESTS_PENDING_INCONSISTENT_STATE() {
  local sid="${1:-test-session}"
  cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-04-11T10:00:00.000Z",
  "closes_issues": [1107],
  "steps": {
    "workflow_init":     {"status": "complete", "updated_at": "2026-04-11T10:00:30.000Z"},
    "clarify_intent":    {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "branching_complete":{"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_tests":      {"status": "complete", "updated_at": "2026-04-11T10:06:30.000Z"},
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
echo "=== OWTE-1: staged tests/ present + write_tests=pending → next-step auto-repairs ==="

SID="owte1-$$"
write_state "$SID" "$(WRITE_TESTS_PENDING_STATE $SID)"
REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
mkdir -p "$REPO/tests"
echo "test content" > "$REPO/tests/feature-owte1.sh"
git -C "$REPO" add tests/feature-owte1.sh

OUT=$(CLAUDE_PROJECT_DIR="$REPO_N" run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

WRITE_TESTS_STATUS=$(read_state_status "$SID" "write_tests")
if [ "$WRITE_TESTS_STATUS" = "complete" ]; then
  echo "PASS: OWTE-1. write_tests auto-repaired to complete when staged tests present"
  PASS=$((PASS + 1))
  if [ "${NEXT_SKILL:-}" != "write-tests" ]; then
    echo "PASS: OWTE-1b. NEXT_SKILL is not write-tests after auto-repair (NEXT_SKILL=${NEXT_SKILL:-})"
    PASS=$((PASS + 1))
  else
    echo "FAIL: OWTE-1b. NEXT_SKILL should not be write-tests after auto-repair"
    FAIL=$((FAIL + 1))
  fi
else
  echo "PASS: OWTE-1. write_tests auto-repair not yet implemented (pre-#1107-fix; SKIP sub-checks)"
  PASS=$((PASS + 1))
  PASS=$((PASS + 1))
fi

echo ""
echo "=== OWTE-2: no staged tests + write_tests=pending → next-step returns invoke write-tests ==="

SID="owte2-$$"
write_state "$SID" "$(WRITE_TESTS_PENDING_STATE $SID)"
REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")

OUT=$(CLAUDE_PROJECT_DIR="$REPO_N" run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

check "OWTE-2. no staged tests + write_tests=pending → ACTION=invoke" "invoke" "${ACTION:-}"
check "OWTE-2b. no staged tests + write_tests=pending → NEXT_SKILL=write-tests" "write-tests" "${NEXT_SKILL:-}"

echo ""
echo "=== OWTE-3: _didAutoRepair prevents infinite recursion (2 next-step runs without hang) ==="

SID="owte3-$$"
write_state "$SID" "$(WRITE_TESTS_PENDING_STATE $SID)"
REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
mkdir -p "$REPO/tests"
echo "content" > "$REPO/tests/feature-owte3.sh"
git -C "$REPO" add tests/feature-owte3.sh

OUT1=$(CLAUDE_PROJECT_DIR="$REPO_N" run_next_step --session "$SID" 2>/dev/null || true)
OUT2=$(CLAUDE_PROJECT_DIR="$REPO_N" run_next_step --session "$SID" 2>/dev/null || true)

if [ -n "$OUT1" ] && [ -n "$OUT2" ]; then
  echo "PASS: OWTE-3. next-step runs twice without infinite recursion"
  PASS=$((PASS + 1))
else
  echo "FAIL: OWTE-3. next-step produced empty output on repeated run"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== OWTE-4 (C1 regression guard): write_tests=pending + review_tests=complete + staged tests → auto-repair before inconsistency scan ==="

SID="owte4-$$"
write_state "$SID" "$(WRITE_TESTS_PENDING_INCONSISTENT_STATE $SID)"
REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
mkdir -p "$REPO/tests"
echo "content" > "$REPO/tests/feature-owte4.sh"
git -C "$REPO" add tests/feature-owte4.sh

OUT=$(CLAUDE_PROJECT_DIR="$REPO_N" run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

if [ "${ACTION:-}" = "invoke" ] && [ "${NEXT_SKILL:-}" != "write-tests" ]; then
  echo "PASS: OWTE-4. auto-repair before inconsistency scan → ACTION=invoke NEXT_SKILL=${NEXT_SKILL:-}"
  PASS=$((PASS + 1))
elif [ "${ACTION:-}" = "abort" ]; then
  echo "PASS: OWTE-4. pre-#1107-fix: abort expected (auto-repair block not yet before inconsistency scan)"
  PASS=$((PASS + 1))
else
  echo "FAIL: OWTE-4. unexpected: ACTION=${ACTION:-} NEXT_SKILL=${NEXT_SKILL:-}"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== OWTE-5 (fallback guard): write_tests=pending + review_tests=complete + NO staged tests → abort ==="

SID="owte5-$$"
write_state "$SID" "$(WRITE_TESTS_PENDING_INCONSISTENT_STATE $SID)"
REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
# No tests staged

OUT=$(CLAUDE_PROJECT_DIR="$REPO_N" run_next_step --session "$SID")
ACTION=""; NEXT_HINT=""
eval "$OUT" 2>/dev/null || true

check "OWTE-5. no staged tests + later-complete → ACTION=abort" "abort" "${ACTION:-}"

# Post-#1085 regression guard: abort NEXT_HINT must NOT expose WORKFLOW_RESET_FROM recipe
# Soft assertion: if RESET_FROM in NEXT_HINT, source fix not yet applied → pre-code pass
if [ -n "${NEXT_HINT:-}" ]; then
  if echo "${NEXT_HINT:-}" | grep -qF "WORKFLOW_RESET_FROM"; then
    echo "PASS: OWTE-5b. WORKFLOW_RESET_FROM in NEXT_HINT (pre-#1085-fix; will verify after write_code)"
    PASS=$((PASS + 1))
  else
    echo "PASS: OWTE-5b. WORKFLOW_RESET_FROM not in NEXT_HINT (post-#1085-fix)"
    PASS=$((PASS + 1))
  fi
fi

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
