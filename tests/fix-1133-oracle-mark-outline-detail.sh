#!/bin/bash
# Tests: hooks/lib/workflow-state/evidence-resolver.js, bin/workflow/next-step, bin/workflow/reconcile-state
# Tags: workflow, oracle, mark, outline, detail, auto-repair, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Real Claude Code session where PostCompact fires and oracle is consulted
# - Actual hook event chain registration
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
#
# Covers #1133 (oracle --mark CLI, outline/detail auto-repair, scoped hints):
#   --mark <step> <status> flag (M1-M6), outline/detail evidence auto-repair (A1-A2),
#   scoped abort hint when outline=pending+detail=complete (H1-H2),
#   generic hint bifurcation by hasCompletionEvidence (B1-B2),
#   reconcile-state --dry-run showing outline/detail in EVIDENCE_STEPS (G1),
#   --mark idempotency (I1), and session-ID path-traversal rejection (S1).

set -euo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORACLE="$AGENTS_DIR/bin/workflow/next-step"
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

# Run the oracle for verdict output (always exits 0; KEY=value lines on stdout).
run_oracle() {
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
    run_with_timeout node "$ORACLE" "$@" 2>/dev/null || true
}

# Run the oracle capturing exit code + stderr.
# Sets globals: RC, STDERR.
run_oracle_rc() {
  local err_file="$TMPDIR_BASE/stderr.$RANDOM"
  set +e
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
    run_with_timeout node "$ORACLE" "$@" >/dev/null 2>"$err_file"
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

# All steps complete up to branching_complete; outline=pending, detail=complete.
# Anomalous: detail completed but outline is still pending (compaction inconsistency).
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

# All steps complete up to write_tests; detail=pending while branching_complete=complete.
# Anomalous: branching_complete complete but detail still pending.
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

# Normal state: outline/detail complete, write_tests current, no inconsistency.
# clarify_intent=complete, no intent.md → B1/B2 use clarify_intent pair instead.
# For B1: create intent.md so hasCompletionEvidence("clarify_intent")=true.
# For B2: no intent.md so hasCompletionEvidence("clarify_intent")=false.
# Use clarify_intent=pending + later step complete to trigger inconsistency scan.
CLARIFY_INTENT_PENDING_RESEARCH_COMPLETE() {
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
    "clarify_intent":    {"status": "pending",  "updated_at": null},
    "research":          {"status": "complete", "updated_at": "2026-06-20T10:02:00.000Z"},
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

# Normal state: all steps complete up to branching_complete.
# outline=complete, detail=complete, branching_complete=pending (current).
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

# ===========================================================================
# === M1-M5: --mark CLI flag ===
# ===========================================================================

echo ""
echo "=== M1: --mark outline complete → exit 0 + state outline=complete ==="

# Use OUTLINE_PENDING_DETAIL_COMPLETE so outline starts as pending — verifies the write.
SID="m1-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
# Sanity: confirm outline is pending before mark.
check "M1-pre. outline is pending before --mark" \
  "pending" "$(read_state_status "$SID" "outline")"
run_oracle_rc --session "$SID" --mark outline complete
check "M1. --mark outline complete → exit 0" "0" "$RC"
check "M1b. --mark outline complete → state shows outline=complete" \
  "complete" "$(read_state_status "$SID" "outline")"

echo ""
echo "=== M2: --mark bogus_step complete → nonzero exit + stderr ==="

SID="m2-$$"
write_state "$SID" "$(NORMAL_BRANCHING_COMPLETE_CURRENT $SID)"
run_oracle_rc --session "$SID" --mark bogus_step complete
check_nonzero "M2. --mark bogus_step complete → nonzero exit" "$RC"
if [ -n "${STDERR:-}" ]; then
  echo "PASS: M2b. --mark bogus_step → stderr error message emitted"
  PASS=$((PASS + 1))
else
  echo "FAIL: M2b. --mark bogus_step → expected stderr error, got empty"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== M3: --mark (no args) → nonzero exit ==="

SID="m3-$$"
write_state "$SID" "$(NORMAL_BRANCHING_COMPLETE_CURRENT $SID)"
run_oracle_rc --session "$SID" --mark
check_nonzero "M3. --mark (no step argument) → nonzero exit" "$RC"

echo ""
echo "=== M4: --mark outline (missing status token) → nonzero exit + stderr ==="

SID="m4-$$"
write_state "$SID" "$(NORMAL_BRANCHING_COMPLETE_CURRENT $SID)"
run_oracle_rc --session "$SID" --mark outline
check_nonzero "M4. --mark outline (no status) → nonzero exit" "$RC"
if [ -n "${STDERR:-}" ]; then
  echo "PASS: M4b. --mark outline (no status) → stderr error emitted"
  PASS=$((PASS + 1))
else
  echo "FAIL: M4b. --mark outline (no status) → expected stderr error, got empty"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== M5: --mark outline invalid_status → nonzero exit + stderr ==="

SID="m5-$$"
write_state "$SID" "$(NORMAL_BRANCHING_COMPLETE_CURRENT $SID)"
run_oracle_rc --session "$SID" --mark outline invalid_status
check_nonzero "M5. --mark outline invalid_status → nonzero exit" "$RC"
if [ -n "${STDERR:-}" ]; then
  echo "PASS: M5b. --mark outline invalid_status → stderr error emitted"
  PASS=$((PASS + 1))
else
  echo "FAIL: M5b. --mark outline invalid_status → expected stderr error, got empty"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== M6: --mark detail complete → exit 0 + state detail=complete (symmetric to M1) ==="

SID="m6-$$"
write_state "$SID" "$(DETAIL_PENDING_BRANCHING_COMPLETE $SID)"
check "M6-pre. detail is pending before --mark" \
  "pending" "$(read_state_status "$SID" "detail")"
run_oracle_rc --session "$SID" --mark detail complete
check "M6. --mark detail complete → exit 0" "0" "$RC"
check "M6b. --mark detail complete → state shows detail=complete" \
  "complete" "$(read_state_status "$SID" "detail")"

# ===========================================================================
# === I1: --mark idempotency ===
# ===========================================================================

echo ""
echo "=== I1: --mark outline complete twice → idempotent (exit 0 both, state=complete) ==="

SID="i1-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
run_oracle_rc --session "$SID" --mark outline complete
check "I1. first --mark outline complete → exit 0" "0" "$RC"
check "I1b. first --mark → state shows outline=complete" \
  "complete" "$(read_state_status "$SID" "outline")"
run_oracle_rc --session "$SID" --mark outline complete
check "I1c. second --mark outline complete → exit 0 (idempotent)" "0" "$RC"
check "I1d. second --mark → state still outline=complete" \
  "complete" "$(read_state_status "$SID" "outline")"

# ===========================================================================
# === S1: Session-ID validation rejects path traversal ===
# ===========================================================================

echo ""
echo "=== S1: --session '../escape' → nonzero exit (SESSION_ID_VALID_RE guard) ==="

# evidence-resolver.js uses SESSION_ID_VALID_RE to prevent path traversal when
# constructing <PLANS_DIR>/<session-id>-outline.md paths.  The CLI must reject
# session IDs that contain '/' or '..' before any file operation occurs.
run_oracle_rc --session "../escape" --mark outline complete
check_nonzero "S1. --session '../escape' → nonzero exit (path traversal rejected)" "$RC"

echo ""
echo "=== S2: --session '' → nonzero exit (empty session ID rejected) ==="

run_oracle_rc --session "" --mark outline complete
check_nonzero "S2. --session '' → nonzero exit (empty session ID rejected)" "$RC"

# ===========================================================================
# === A1-A2: outline/detail evidence-based auto-repair ===
# ===========================================================================

echo ""
echo "=== A1: outline=pending + detail=complete + outline.md exists → auto-repair → branching_complete ==="

SID="a1-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
# Create the outline.md artifact in PLANS_DIR to trigger evidence-based auto-repair.
touch "$PLANS_DIR/${SID}-outline.md"

OUT=$(run_oracle --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

# After auto-repair: outline=complete, detail=complete → next step is branching_complete.
check "A1. outline.md exists + detail=complete → ACTION=invoke (branching_complete)" \
  "invoke" "${ACTION:-}"
check "A1b. outline.md auto-repair → NEXT_SKILL='' (branching_complete has no skill)" \
  "" "${NEXT_SKILL:-}"
# The state should have been repaired: outline must now be complete.
check "A1c. outline.md auto-repair → state shows outline=complete" \
  "complete" "$(read_state_status "$SID" "outline")"

# Cleanup for isolation.
rm -f "$PLANS_DIR/${SID}-outline.md"

echo ""
echo "=== A2: detail=pending + detail.md exists → auto-repair → branching_complete ==="

SID="a2-$$"
write_state "$SID" "$(DETAIL_PENDING_BRANCHING_COMPLETE $SID)"
# Create the detail.md artifact in PLANS_DIR to trigger evidence-based auto-repair.
touch "$PLANS_DIR/${SID}-detail.md"

OUT=$(run_oracle --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

# After auto-repair: detail=complete, branching_complete=complete → next step is write_tests.
# Actually branching_complete is already complete in this fixture, so next is write_tests.
check "A2. detail.md exists + branching_complete=complete → ACTION=invoke" \
  "invoke" "${ACTION:-}"
check "A2b. detail.md auto-repair → state shows detail=complete" \
  "complete" "$(read_state_status "$SID" "detail")"

rm -f "$PLANS_DIR/${SID}-detail.md"

# ===========================================================================
# === H1-H2: Scoped abort hint for outline=pending + detail=complete ===
# ===========================================================================

echo ""
echo "=== H1: outline=pending + detail=complete + no outline.md → abort + hint has --mark outline complete ==="

SID="h1-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
# No outline.md → no evidence → auto-repair does not fire → inconsistency scan fires.

OUT=$(run_oracle --session "$SID")
ACTION=""; NEXT_HINT=""
eval "$OUT" 2>/dev/null || true

check "H1. outline=pending + detail=complete (no evidence) → ACTION=abort" \
  "abort" "${ACTION:-}"
check_contains "H1b. scoped hint contains --mark outline complete" \
  "--mark outline complete" "${NEXT_HINT:-}"

echo ""
echo "=== H2: H1 hint does NOT contain /workflow-init ==="

# Re-use the same state from H1 (same SID, state already written).
OUT=$(run_oracle --session "$SID")
ACTION=""; NEXT_HINT=""
eval "$OUT" 2>/dev/null || true

check_not_contains "H2. outline=pending + detail=complete scoped hint does NOT contain /workflow-init" \
  "/workflow-init" "${NEXT_HINT:-}"

# ===========================================================================
# === B1-B2: Generic hint bifurcation by hasCompletionEvidence ===
# ===========================================================================
# Use clarify_intent=pending + research=complete (non-outline/detail pair).
# B1: intent.md exists → hasCompletionEvidence("clarify_intent")=true
#     → after auto-complete, oracle advances. But we need to test the hint path,
#     not the auto-repair path. So: test the inconsistency case where
#     clarify_intent=pending + a LATER step is complete + intent.md does NOT exist
#     (B2) vs does exist (B1).
#     When intent.md exists, clarify_intent auto-repair fires and the
#     inconsistency is healed → not an abort. So for B1 we need a different pair
#     where evidence exists but auto-repair won't advance past the inconsistency.
#
# Simpler approach: test a pair where evidence check is used in the HINT only,
# not in auto-repair. The inconsistency scan hint bifurcation:
#   - if hasCompletionEvidence(currentStep) → hint suggests "--mark <step> complete"
#   - if !hasCompletionEvidence(currentStep) → hint suggests "/workflow-init"
#
# For this to be testable without auto-repair interfering, use outline=pending
# + detail=complete (same as H1/H2) but:
#   B1: outline.md exists → hasCompletionEvidence("outline")=true → --mark hint
#   B2: no outline.md → hasCompletionEvidence("outline")=false → /workflow-init hint
#
# Wait — if outline.md exists, A1 auto-repair fires BEFORE the inconsistency scan.
# So B1 (with outline.md) would produce invoke, not abort.
# Therefore for B1 we must test a NON-auto-repairable step that still supports
# evidence checks for hint bifurcation.
#
# Use clarify_intent=pending + research=complete:
#   - clarify_intent has evidence check: intent.md exists
#   - auto-repair fires when intent.md exists → advances past clarify_intent
#   - So B1 with intent.md → auto-repair fires → not abort → N/A for hint test
#
# The only clean pair is write_tests=pending + run_tests=complete (#1139 pattern):
#   B1: staged test files → hasCompletionEvidence("write_tests")=true
#       → auto-repair fires before inconsistency scan (#1107) → not abort
#   So auto-repair blocks the hint test for any evidence-supported step.
#
# Therefore B1/B2 must be tested at the --mark hint level: when the oracle
# emits the hint for a non-auto-repaired inconsistency, the hint should
# bifurcate based on evidence. The only current non-auto-repaired evidence
# pair is one that is ADDED by #1133 (outline/detail). Since outline has
# auto-repair (A1), let's test the hint text directly.
#
# For B2 (no evidence → /workflow-init), use the H1/H2 state (no outline.md):
# hint must NOT contain "--mark". We already checked H2.
#
# For B1 (evidence present but auto-repair should NOT suppress the hint):
# We need a state where the evidence predicate is true for the CURRENT step
# but auto-repair is bypassed (e.g. _didAutoRepair=true guard).
# We cannot directly set _didAutoRepair. But we can test the boundary indirectly:
# after auto-repair runs once (A1), the state is fixed. Then if we call oracle
# again, outline=complete, no inconsistency → invoke.
#
# Simplest testable B1/B2: use a pair where current step has NO auto-repair
# but hasCompletionEvidence bifurcates the hint. The current implementation
# only has auto-repair for clarify_intent, docs, write_tests (and post-#1133:
# outline, detail). The inconsistency hint for non-repaired pairs uses generic
# /workflow-init text. After #1133 lands, the non-repaired case with evidence
# uses --mark. We test this by checking the hint for outline=pending+detail=complete:
#   B1: outline.md present → would auto-repair → ACTION=invoke, not abort.
#       To get the hint-bifurcation path, we need auto-repair to have ALREADY run
#       (second pass). We simulate by writing state after a first auto-repair pass.
#       After first pass: outline=complete → no inconsistency → invoke.
#       So B1 from the inconsistency hint path is unreachable if auto-repair works.
#
# Revised approach: B1/B2 test the GENERAL non-outline/non-detail inconsistency:
#   B1: review_security=complete + run_tests=pending → non-scoped abort.
#       hint should contain "--mark" when run_tests has evidence (staged tests).
#       But we can't easily stage test files in this test environment.
#   B2: review_security=complete + run_tests=pending, no staged tests →
#       hint contains "/workflow-init" (generic stale-state path).
#
# For B1: use a repo with a staged test file → hasStagedTestChanges() = true.
# For B2: use a clean repo → no staged test → hasStagedTestChanges() = false.

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

echo ""
echo "=== B1: non-scoped pair + hasCompletionEvidence=true → hint has --mark ==="

SID="b1-$$"
write_state "$SID" "$(REVIEW_SECURITY_COMPLETE_RUN_TESTS_PENDING $SID)"
REPO_B1=$(setup_repo)
# Stage a test file so hasStagedTestChanges() returns true for run_tests evidence.
mkdir -p "$REPO_B1/tests"
echo "# test" > "$REPO_B1/tests/dummy.sh"
git -C "$REPO_B1" add "tests/dummy.sh"
REPO_B1_N=$(to_node_path "$REPO_B1")

OUT=$(CLAUDE_PROJECT_DIR="$REPO_B1_N" run_oracle --session "$SID")
ACTION=""; NEXT_HINT=""
eval "$OUT" 2>/dev/null || true

check "B1. review_security=complete + run_tests=pending + staged tests → ACTION=abort" \
  "abort" "${ACTION:-}"
check_contains "B1b. hint with evidence → contains --mark" \
  "--mark" "${NEXT_HINT:-}"

echo ""
echo "=== B2: non-scoped pair + hasCompletionEvidence=false → hint has /workflow-init not --mark ==="

SID="b2-$$"
write_state "$SID" "$(REVIEW_SECURITY_COMPLETE_RUN_TESTS_PENDING $SID)"
REPO_B2=$(setup_repo)
# No staged test files → hasStagedTestChanges() = false.
REPO_B2_N=$(to_node_path "$REPO_B2")

OUT=$(CLAUDE_PROJECT_DIR="$REPO_B2_N" run_oracle --session "$SID")
ACTION=""; NEXT_HINT=""
eval "$OUT" 2>/dev/null || true

check "B2. review_security=complete + run_tests=pending + no evidence → ACTION=abort" \
  "abort" "${ACTION:-}"
check_contains "B2b. hint without evidence → contains /workflow-init" \
  "/workflow-init" "${NEXT_HINT:-}"
check_not_contains "B2c. hint without evidence → does NOT contain --mark" \
  "--mark" "${NEXT_HINT:-}"

# ===========================================================================
# === G1: reconcile-state --dry-run shows outline/detail in EVIDENCE_STEPS ===
# ===========================================================================

echo ""
echo "=== G1: reconcile-state --dry-run shows outline/detail in EVIDENCE_STEPS ==="

SID="g1-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
# No evidence artifacts → steps should show "pending (no evidence)".

run_reconcile --session "$SID" --dry-run

check_contains "G1. reconcile-state --dry-run output mentions outline" \
  "outline" "${RECONCILE_OUT:-}"
check_contains "G1b. reconcile-state --dry-run output mentions detail" \
  "detail" "${RECONCILE_OUT:-}"

# Also verify that when outline.md exists, reconcile-state would mark it complete.
SID="g1b-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
touch "$PLANS_DIR/${SID}-outline.md"

run_reconcile --session "$SID" --dry-run

check_contains "G1c. reconcile-state --dry-run with outline.md → would update outline" \
  "outline" "${RECONCILE_OUT:-}"
# Expect "would update" or "pending -> complete" in the output.
if echo "${RECONCILE_OUT:-}" | grep -qiE "would update|pending.*complete"; then
  echo "PASS: G1d. reconcile-state --dry-run with outline.md → shows pending->complete transition"
  PASS=$((PASS + 1))
else
  echo "FAIL: G1d. reconcile-state --dry-run with outline.md → expected pending->complete, got: ${RECONCILE_OUT:-}"
  FAIL=$((FAIL + 1))
fi

rm -f "$PLANS_DIR/${SID}-outline.md"

# ===========================================================================
echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
