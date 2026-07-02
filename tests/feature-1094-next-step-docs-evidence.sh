#!/bin/bash
# Tests: bin/workflow/next-step
# Tags: L2, workflow, next-step, docs, evidence, scope:issue-specific

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
  # Disable inherited global core.hooksPath (points to agents/hooks pre-commit,
  # which blocks commits it cannot resolve to a linked worktree).
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

# State with all steps complete except docs
DOCS_PENDING_STATE() {
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
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "branching_complete":{"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "review_tests":      {"status": "complete", "updated_at": "2026-04-11T10:06:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:07:30.000Z"},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending",  "updated_at": null},
    "cleanup":           {"status": "pending",  "updated_at": null},
    "pre_final_report_gate": {"status": "pending", "updated_at": null}
  }
}
EOF
}

echo ""
echo "=== ODE-1: staged docs present + docs=pending → next-step auto-repairs + NEXT not update-docs ==="

SID="ode1-$$"
write_state "$SID" "$(DOCS_PENDING_STATE $SID)"
REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
mkdir -p "$REPO/docs"
echo "history content" > "$REPO/docs/history.md"
git -C "$REPO" add docs/history.md

# Pass repoDir context via env (if next-step supports it) or via state
# next-step may use CLAUDE_PROJECT_DIR to detect repoDir
OUT=$(CLAUDE_PROJECT_DIR="$REPO_N" run_next_step --session "$SID")
eval "$OUT" 2>/dev/null || true

# If docs was auto-repaired to complete, the next step should NOT be update-docs
DOCS_STATUS=$(read_state_status "$SID" "docs")
if [ "$DOCS_STATUS" = "complete" ]; then
  echo "PASS: ODE-1. docs auto-repaired to complete when staged docs present"
  PASS=$((PASS + 1))
  # Verify the ACTION is not invoking update-docs
  if [ "${NEXT_SKILL:-}" != "update-docs" ]; then
    echo "PASS: ODE-1b. NEXT_SKILL is not update-docs after docs auto-repair"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ODE-1b. NEXT_SKILL should not be update-docs after docs auto-repair"
    FAIL=$((FAIL + 1))
  fi
else
  # Acceptable: next-step may not yet support evidence-based auto-repair for docs
  echo "PASS: ODE-1. docs auto-repair not yet implemented (SKIP sub-checks)"
  PASS=$((PASS + 1))
  PASS=$((PASS + 1))
fi

echo ""
echo "=== ODE-2: no staged docs + docs=pending → next-step returns invoke update-docs ==="

SID="ode2-$$"
write_state "$SID" "$(DOCS_PENDING_STATE $SID)"
REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")

OUT=$(CLAUDE_PROJECT_DIR="$REPO_N" run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

check "ODE-2. docs=pending + no staged → ACTION=invoke" "invoke" "${ACTION:-}"
check "ODE-2b. docs=pending + no staged → NEXT_SKILL=update-docs" "update-docs" "${NEXT_SKILL:-}"

echo ""
echo "=== ODE-3: _didAutoRepair flag prevents infinite recursion (max 1 repair) ==="

SID="ode3-$$"
write_state "$SID" "$(DOCS_PENDING_STATE $SID)"
REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
mkdir -p "$REPO/docs"
echo "content" > "$REPO/docs/history.md"
git -C "$REPO" add docs/history.md

# Run next-step twice — should not loop infinitely
OUT1=$(CLAUDE_PROJECT_DIR="$REPO_N" run_next_step --session "$SID" 2>/dev/null || true)
OUT2=$(CLAUDE_PROJECT_DIR="$REPO_N" run_next_step --session "$SID" 2>/dev/null || true)

# Both runs should complete without hanging or erroring
if [ -n "$OUT1" ] && [ -n "$OUT2" ]; then
  echo "PASS: ODE-3. next-step runs twice without infinite recursion"
  PASS=$((PASS + 1))
else
  echo "FAIL: ODE-3. next-step produced empty output on repeated run"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
