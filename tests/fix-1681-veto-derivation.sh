#!/usr/bin/env bash
# filename: tests/fix-1681-veto-derivation.sh
# Tests: bin/workflow/next-step, hooks/workflow-gate.js, hooks/session-start.js, hooks/workflow-state/effective-state.js, hooks/lib/workflow-state/state-io.js, bin/workflow/lib/next-step/
# Tags: workflow, skip-verdict, veto, derivation, next-step, workflow-gate, session-start, TL2, scope:common
#
# #1681: a recorded outline skip_verdict=veto never de-skips the step, so
# make-detail-plan stays reachable and the workflow can never be corrected.
# Per the #1352 reset contract, a vetoed step must read back as effective-pending
# AND every later step must become effective-pending too — WITHOUT rewriting
# state.json (read-time derivation only; state.json stays the raw record).
#
# RED: the veto cases fail against the unmodified sources (no derivation layer).
# V6 and V9 are regression guards for existing behavior and pass both before
# and after the fix.
#
# TL3 gap (what this test does NOT catch):
# - Real CLAUDE_SESSION_ID propagation from a live `claude -p` session into the
#   next-step / hook invocations.
# - Real SessionStart hook registration actually firing in the Claude Code host.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEXT_STEP="$AGENTS_DIR/bin/workflow/next-step"
GATE_HOOK="$AGENTS_DIR/hooks/workflow-gate.js"
SESSION_START="$AGENTS_DIR/hooks/session-start.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

check_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then pass "$desc"
    else fail "$desc -- expected [$expected] got [$actual]"; fi
}

check_ne() {
    local desc="$1" unexpected="$2" actual="$3"
    if [ "$actual" != "$unexpected" ]; then pass "$desc"
    else fail "$desc -- did NOT expect [$unexpected]"; fi
}

check_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then pass "$desc"
    else fail "$desc -- expected [$needle] in: $haystack"; fi
}

check_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        fail "$desc -- did NOT expect [$needle] in: $haystack"
    else pass "$desc"; fi
}

# ---------------------------------------------------------------------------
# Windows-compatible tmpdir shared between bash and Node.js
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    TMPDIR_BASE=$(mktemp -d "/${_DRIVE}${_REST}/cctests1681.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

to_node_path() { echo "$1" | sed 's|^/\([a-zA-Z]\)/|\1:/|'; }

WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
export CLAUDE_WORKFLOW_DIR="$(to_node_path "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(to_node_path "$PLANS_DIR")"

setup_repo() {
    local repo="$TMPDIR_BASE/repo-$RANDOM-$$"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath ""
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial" --no-verify
    echo "$repo"
}

# write_state <sid> <overrides-json>
# overrides-json maps step name -> partial step object (status, skip_verdict, ...).
# Every unnamed step defaults to pending.
write_state() {
    local sid="$1" overrides="$2"
    node -e '
const [sid, overrides, out] = process.argv.slice(1);
// #1665 inserted write_code between review_tests and run_tests. A step absent from this
// list cannot be addressed by an override, so it would stay pending and could become the
// current step instead of the one a case is aiming at.
const STEPS = ["workflow_init","clarify_intent","research","outline","detail",
  "branching_complete","write_tests","review_tests","write_code","run_tests","review_security",
  "docs","user_verification","cleanup","pre_final_report_gate"];
const o = JSON.parse(overrides);
const now = new Date().toISOString();
const steps = {};
for (const s of STEPS) {
  steps[s] = Object.assign({ status: "pending", updated_at: null }, o[s] || {});
  if (steps[s].status !== "pending") steps[s].updated_at = steps[s].updated_at || now;
}
const approval = (step) => ({ source: "confirm-flag-off", reason: "test fixture",
  artifact_sha256: null, artifact_session_id: sid,
  artifact_hash_status: "not-applicable", recorded_at: now });
const state = { version: 1, session_id: sid, git_branch: "main", is_bugfix: false,
  workflow_type: "wf-code", created_at: now, steps, closes_issues: [1681],
  plan_approvals: { outline: approval("outline"), detail: approval("detail") } };
require("fs").writeFileSync(out, JSON.stringify(state, null, 2), "utf8");
' "$sid" "$overrides" "$(to_node_path "$WORKFLOW_DIR/$sid.json")"
}

raw_step_field() {
    local sid="$1" step="$2" field="$3"
    # #1733: on disk, v2 state persists .steps only under the .current projection
    # (top-level events are the SSOT); fall back to that shape.
    node -e '
const [f, step, field] = process.argv.slice(1);
try {
  const s = JSON.parse(require("fs").readFileSync(f, "utf8"));
  const steps = s.steps || (s.current && s.current.steps);
  const v = steps && steps[step] && steps[step][field];
  process.stdout.write(v === undefined || v === null ? "" : String(v));
} catch (e) { process.stdout.write("MISSING"); }
' "$(to_node_path "$WORKFLOW_DIR/$sid.json")" "$step" "$field"
}

run_next_step() { run_with_timeout 120 node "$NEXT_STEP" "$@" 2>/dev/null || true; }

run_gate() {
    local repo="$1" sid="$2"
    local json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $repo commit -m test\",\"cwd\":\"$repo\"},\"session_id\":\"$sid\"}"
    echo "$json" | CLAUDE_PROJECT_DIR="$repo" AGENTS_CONFIG_DIR="$repo" \
        run_with_timeout 120 node "$GATE_HOOK" 2>/dev/null || true
}

# Steps before outline, all cleared.
PRE_OUTLINE='"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"}'
# Everything after detail, all cleared (used by the "only the veto blocks" fixtures).
POST_DETAIL='"branching_complete":{"status":"complete"},"write_tests":{"status":"complete"},"review_tests":{"status":"complete"},"write_code":{"status":"complete"},"run_tests":{"status":"complete"},"review_security":{"status":"complete"},"docs":{"status":"complete"},"user_verification":{"status":"complete"},"cleanup":{"status":"complete"},"pre_final_report_gate":{"status":"complete"}'
VETOED_OUTLINE='"outline":{"status":"skipped","skip_reason":"speculative","skip_verdict":{"verdict":"veto","source":"skip-verifier","recorded_at":"2026-07-01T00:00:00.000Z"}}'
PENDING_VERDICT_OUTLINE='"outline":{"status":"skipped","skip_reason":"speculative","skip_verdict":{"verdict":"pending","source":"next-step-recorded-verdict","recorded_at":"2026-07-01T00:00:00.000Z"}}'

echo "=== fix-1681: veto de-skip derivation (TL2) ==="

# ---------------------------------------------------------------------------
# V1: vetoed outline must not leave make-detail-plan reachable.
# ---------------------------------------------------------------------------
V1_SID="v1-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$V1_SID" "{$PRE_OUTLINE,$VETOED_OUTLINE,\"detail\":{\"status\":\"pending\"}}"
ACTION=""; NEXT_SKILL=""; REASON=""; NEXT_HINT=""
V1_OUT="$(run_next_step --session "$V1_SID")"
eval "$V1_OUT" 2>/dev/null || true
check_ne "V1: vetoed outline → NEXT_SKILL is not make-detail-plan" \
    "make-detail-plan" "${NEXT_SKILL:-}"
if [ "${NEXT_SKILL:-}" = "make-outline-plan" ] || printf '%s' "${REASON:-}" | grep -qF "outline"; then
    pass "V1: outline is the current/blocking step"
else
    fail "V1: expected outline to be current/blocking, got: $V1_OUT"
fi

# ---------------------------------------------------------------------------
# V2: derivation is read-time only — state.json must NOT be rewritten.
# ---------------------------------------------------------------------------
check_eq "V2: on-disk outline.status still literally skipped (no rewrite)" \
    "skipped" "$(raw_step_field "$V1_SID" "outline" "status")"

# ---------------------------------------------------------------------------
# V3: skip_verdict still pending (no verdict yet) → blocked, not advanced.
# ---------------------------------------------------------------------------
V3_SID="v3-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$V3_SID" "{$PRE_OUTLINE,$PENDING_VERDICT_OUTLINE,\"detail\":{\"status\":\"pending\"}}"
ACTION=""; NEXT_SKILL=""; REASON=""; NEXT_HINT=""
V3_OUT="$(run_next_step --session "$V3_SID")"
eval "$V3_OUT" 2>/dev/null || true
check_eq "V3: pending skip verdict → ACTION=blocked" "blocked" "${ACTION:-}"
check_contains "V3: REASON=speculative-skip-pending" "speculative-skip-pending" "${REASON:-}"

# ---------------------------------------------------------------------------
# V4: the commit gate must block on a vetoed step. The fixture clears every
# other step, so a block here is attributable to the veto alone.
# ---------------------------------------------------------------------------
V4_SID="v4-$(printf '%04x%04x' $RANDOM $RANDOM)"
V4_REPO="$(setup_repo)"
write_state "$V4_SID" "{$PRE_OUTLINE,$VETOED_OUTLINE,\"detail\":{\"status\":\"complete\"},$POST_DETAIL}"
V4_RESULT="$(run_gate "$V4_REPO" "$V4_SID")"
check_contains "V4: commit gate blocks while outline is vetoed" '"block"' "$V4_RESULT"

# ---------------------------------------------------------------------------
# V5: detail has no usable input (no intent.md, no outline.md) → blocked.
# ---------------------------------------------------------------------------
V5_SID="v5-$(printf '%04x%04x' $RANDOM $RANDOM)"
write_state "$V5_SID" "{$PRE_OUTLINE,\"outline\":{\"status\":\"skipped\",\"skip_reason\":\"not needed\"},\"detail\":{\"status\":\"pending\"}}"
rm -f "$PLANS_DIR/${V5_SID}-intent.md" "$PLANS_DIR/${V5_SID}-outline.md"
ACTION=""; NEXT_SKILL=""; REASON=""; NEXT_HINT=""
V5_OUT="$(run_next_step --session "$V5_SID")"
eval "$V5_OUT" 2>/dev/null || true
check_eq "V5: detail with no intent.md/outline.md → ACTION=blocked" "blocked" "${ACTION:-}"
check_contains "V5: REASON names the missing detail input" "detail-input-missing" "${REASON:-}"

# ---------------------------------------------------------------------------
# V6 (regression guard): staged docs evidence still exempts the docs step even
# when another step (run_tests) is pending. Must hold before AND after the fix.
# ---------------------------------------------------------------------------
V6_SID="v6-$(printf '%04x%04x' $RANDOM $RANDOM)"
V6_REPO="$(setup_repo)"
mkdir -p "$V6_REPO/docs" "$V6_REPO/src"
echo "# notes" > "$V6_REPO/docs/notes.md"
echo "x" > "$V6_REPO/src/x.js"
git -C "$V6_REPO" add docs/notes.md src/x.js
write_state "$V6_SID" "{$PRE_OUTLINE,\"outline\":{\"status\":\"complete\"},\"detail\":{\"status\":\"complete\"},\"branching_complete\":{\"status\":\"complete\"},\"write_tests\":{\"status\":\"complete\"},\"review_tests\":{\"status\":\"complete\"},\"run_tests\":{\"status\":\"pending\"},\"review_security\":{\"status\":\"complete\"},\"docs\":{\"status\":\"pending\"},\"user_verification\":{\"status\":\"complete\"},\"cleanup\":{\"status\":\"complete\"},\"pre_final_report_gate\":{\"status\":\"complete\"}}"
V6_RESULT="$(run_gate "$V6_REPO" "$V6_SID")"
check_contains "V6: gate blocks on the genuinely pending run_tests" "run_tests" "$V6_RESULT"
check_not_contains "V6: docs stays exempt via staged docs evidence" "  docs: run" "$V6_RESULT"

# ---------------------------------------------------------------------------
# V7: session-start must surface the raw recorded status alongside the derived
# effective one — never silently replace it.
# ---------------------------------------------------------------------------
V7_SID="v7-$(printf '%04x%04x' $RANDOM $RANDOM)"
V7_REPO="$(setup_repo)"
write_state "$V7_SID" "{$PRE_OUTLINE,$VETOED_OUTLINE,\"detail\":{\"status\":\"pending\"}}"
V7_OUT=$(echo "{\"session_id\":\"$V7_SID\"}" | \
    CLAUDE_PROJECT_DIR="$V7_REPO" \
    CLAUDE_ENV_FILE="$TMPDIR_BASE/env-v7.env" \
    run_with_timeout 60 node "$SESSION_START" 2>/dev/null || true)
check_contains "V7: workflow status shows 'pending (recorded: skipped)' for the vetoed step" \
    "pending (recorded: skipped)" "$V7_OUT"

# ---------------------------------------------------------------------------
# V8 (#1352 reset contract): later steps already recorded complete must read as
# effective-pending once an earlier step is vetoed — without a state rewrite and
# without tripping the inconsistency abort.
# ---------------------------------------------------------------------------
V8_SID="v8-$(printf '%04x%04x' $RANDOM $RANDOM)"
V8_REPO="$(setup_repo)"
write_state "$V8_SID" "{$PRE_OUTLINE,$VETOED_OUTLINE,\"detail\":{\"status\":\"complete\"},$POST_DETAIL}"
ACTION=""; NEXT_SKILL=""; REASON=""; NEXT_HINT=""
V8_OUT="$(run_next_step --session "$V8_SID")"
eval "$V8_OUT" 2>/dev/null || true
check_eq "V8: next-step ACTION=invoke (not abort) despite later complete steps" \
    "invoke" "${ACTION:-}"
check_eq "V8: next-step routes back to make-outline-plan" \
    "make-outline-plan" "${NEXT_SKILL:-}"
check_eq "V8: on-disk detail.status still literally complete (no rewrite)" \
    "complete" "$(raw_step_field "$V8_SID" "detail" "status")"
V8_GATE="$(run_gate "$V8_REPO" "$V8_SID")"
check_contains "V8: commit gate still blocks despite detail/write_tests complete" \
    '"block"' "$V8_GATE"

# ---------------------------------------------------------------------------
# V9 (evidence-policy non-widening): the commit gate resolves write_tests from
# STAGED evidence only. A test file that is merely committed must not satisfy
# it. bin/workflow/next-step may resolve the same scenario under a broader
# evidence policy — that asymmetry is intentional: the gate is the enforcement
# point and is deliberately stricter than next-step's advisory display.
# ---------------------------------------------------------------------------
V9_SID="v9-$(printf '%04x%04x' $RANDOM $RANDOM)"
V9_REPO="$(setup_repo)"
mkdir -p "$V9_REPO/tests" "$V9_REPO/src"
echo "echo test" > "$V9_REPO/tests/committed-test.sh"
git -C "$V9_REPO" add tests/committed-test.sh
git -C "$V9_REPO" commit -q -m "add test" --no-verify
echo "y" > "$V9_REPO/src/y.js"
git -C "$V9_REPO" add src/y.js
write_state "$V9_SID" "{$PRE_OUTLINE,\"outline\":{\"status\":\"complete\"},\"detail\":{\"status\":\"complete\"},\"branching_complete\":{\"status\":\"complete\"},\"write_tests\":{\"status\":\"pending\"},\"review_tests\":{\"status\":\"complete\"},\"run_tests\":{\"status\":\"complete\"},\"review_security\":{\"status\":\"complete\"},\"docs\":{\"status\":\"complete\"},\"user_verification\":{\"status\":\"complete\"},\"cleanup\":{\"status\":\"complete\"},\"pre_final_report_gate\":{\"status\":\"complete\"}}"
V9_RESULT="$(run_gate "$V9_REPO" "$V9_SID")"
check_contains "V9: gate blocks — committed-but-unstaged tests do not satisfy staged-only" \
    "write_tests" "$V9_RESULT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
