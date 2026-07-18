#!/usr/bin/env bash
# tests/feature-943-e2e-stop-confirm-plan-guard.sh
# Tests: hooks/stop-confirm-plan-guard.js
# Tags: e2e, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Direct-stdin drives the hook with a synthesized transcript + turn marker; it
#   does not exercise the real show-plan-link.js PostToolUse marker-write path or
#   a live claude -p Stop event, so ordering races between marker write and Stop
#   only surface in a real session.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/stop-confirm-plan-guard.js"

# Skip gates (3-stage) — direct-stdin needs node + the hook, not claude.
command -v node >/dev/null 2>&1 || { echo "SKIP: node not found" >&2; exit 77; }
[ -f "$HOOK" ] || { echo "SKIP: hook not found: $HOOK" >&2; exit 77; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# On MSYS/Git-Bash, node resolves paths as native Windows; pass Windows-form
# paths to node-based hooks so env vars and file writes stay consistent.
# No-op on POSIX (cygpath absent).
if command -v cygpath >/dev/null 2>&1; then TMP="$(cygpath -m "$TMP")"; fi

# Isolate all hook state from real workflow dirs.
export CLAUDE_WORKFLOW_DIR="$TMP/workflow"
export WORKFLOW_PLANS_DIR="$TMP/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"

SID="feature943-cpg-00000000-0000-0000-0000-000000000001"

# The forbidden path representation the guard scans for is the plans dir itself.
# Resolve it via the hook's own getWorkflowPlansDir() so the string matches
# exactly (MSYS /tmp vs Windows C:/ path forms would otherwise diverge).
PLANS_PATH="$(node -e '
  process.stdout.write(require(require("path").join(process.argv[1], "hooks", "lib", "workflow-plans-dir.js")).getWorkflowPlansDir());
' "$AGENTS_DIR")"

# Build a transcript JSONL whose last assistant message contains $1 (text body).
make_transcript() {
  local body="$1" out="$2"
  node -e '
    const fs = require("fs");
    const body = process.argv[1];
    const out = process.argv[2];
    const entry = { type: "assistant", message: { content: [{ type: "text", text: body }] } };
    fs.writeFileSync(out, JSON.stringify(entry) + "\n", "utf8");
  ' "$body" "$out"
}

# Drop a confirm-plan turn marker for SID so the guard is armed.
arm_marker() {
  node -e '
    const path = require("path");
    process.env.CLAUDE_WORKFLOW_DIR = process.argv[2];
    const { writeTurnMarker } = require(path.join(process.argv[3], "hooks", "lib", "turn-marker.js"));
    writeTurnMarker(process.argv[1], { source: "test" });
  ' "$SID" "$CLAUDE_WORKFLOW_DIR" "$AGENTS_DIR"
}

run_hook() {
  local transcript="$1"
  printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"transcript_path\":\"$transcript\"}" \
    | node "$HOOK"
}

# --- E1: no marker → pass (exit 0) --------------------------------------------
rm -f "$CLAUDE_WORKFLOW_DIR"/*.confirm-plan-turn-* 2>/dev/null || true
T1="$TMP/t1.jsonl"
make_transcript "Here is the plan at $PLANS_PATH somewhere." "$T1"
set +e
OUT1="$(run_hook "$T1")"; EXIT1=$?
set -e
if [ "$EXIT1" -eq 0 ]; then
  pass "E1. no turn marker → Stop hook pass (exit 0)"
else
  fail "E1. no turn marker should pass but exit=$EXIT1 out=$OUT1"
fi

# --- E2: marker + path present → block (exit 2 + decision:block) [ACTIVE] ------
arm_marker
T2="$TMP/t2.jsonl"
make_transcript "The plan lives at $PLANS_PATH — open it." "$T2"
set +e
OUT2="$(run_hook "$T2")"; EXIT2=$?
set -e
if [ "$EXIT2" -eq 2 ] && printf '%s' "$OUT2" | grep -q '"decision":"block"'; then
  pass "E2. marker + path present → block (exit 2 + decision:block)"
else
  fail "E2. expected exit 2 + decision:block; got exit=$EXIT2 out=$OUT2"
fi

# --- E3: marker + no path → pass (exit 0) -------------------------------------
arm_marker
T3="$TMP/t3.jsonl"
make_transcript "The plan is ready. See the breadcrumb above for the file." "$T3"
set +e
OUT3="$(run_hook "$T3")"; EXIT3=$?
set -e
if [ "$EXIT3" -eq 0 ]; then
  pass "E3. marker + no path representation → pass (exit 0)"
else
  fail "E3. marker + no path should pass but exit=$EXIT3 out=$OUT3"
fi

# --- E4: Layer 2 — CONFIRM_INTENT present, no follow-up Skill → block ---------
# Build a transcript whose content array has a Bash tool_use with CONFIRM_INTENT
# echo but no Skill tool_use after it.  The marker must be armed so Layer 1 runs
# and passes (no path string); then Layer 2 should fire the block.
arm_marker
T4="$TMP/t4.jsonl"
node -e '
  const fs = require("fs");
  const out = process.argv[1];
  const entry = { type: "assistant", message: { content: [
    { type: "tool_use", name: "Bash",
      input: { command: "echo \"<<WORKFLOW_CONFIRM_INTENT: intent confirmed>>\""} },
    { type: "text", text: "Intent confirmed." },
  ] } };
  fs.writeFileSync(out, JSON.stringify(entry) + "\n", "utf8");
' "$T4"
set +e
OUT4="$(run_hook "$T4")"; EXIT4=$?
set -e
if [ "$EXIT4" -eq 2 ] && printf '%s' "$OUT4" | grep -q '"decision":"block"'; then
  pass "E4. Layer 2: CONFIRM_INTENT + no follow-up Skill → block (exit 2 + decision:block)"
else
  fail "E4. expected exit 2 + decision:block; got exit=$EXIT4 out=$OUT4"
fi

# --- E5: Layer 2 — CONFIRM_INTENT + valid Skill follow-up → pass --------------
arm_marker
T5="$TMP/t5.jsonl"
node -e '
  const fs = require("fs");
  const out = process.argv[1];
  const entry = { type: "assistant", message: { content: [
    { type: "tool_use", name: "Bash",
      input: { command: "echo \"<<WORKFLOW_CONFIRM_INTENT: intent confirmed>>\""} },
    { type: "tool_use", name: "Skill", input: { skill: "make-outline-plan" } },
  ] } };
  fs.writeFileSync(out, JSON.stringify(entry) + "\n", "utf8");
' "$T5"
set +e
OUT5="$(run_hook "$T5")"; EXIT5=$?
set -e
if [ "$EXIT5" -eq 0 ]; then
  pass "E5. Layer 2: CONFIRM_INTENT + valid make-outline-plan Skill → pass (exit 0)"
else
  fail "E5. expected exit 0 (pass); got exit=$EXIT5 out=$OUT5"
fi

# --- E6: Layer 2 — CONFIRM_OUTLINE + no follow-up Skill → block ---------------
arm_marker
T6="$TMP/t6.jsonl"
node -e '
  const fs = require("fs");
  const out = process.argv[1];
  const entry = { type: "assistant", message: { content: [
    { type: "tool_use", name: "Bash",
      input: { command: "echo \"<<WORKFLOW_CONFIRM_OUTLINE: outline confirmed>>\""} },
  ] } };
  fs.writeFileSync(out, JSON.stringify(entry) + "\n", "utf8");
' "$T6"
set +e
OUT6="$(run_hook "$T6")"; EXIT6=$?
set -e
if [ "$EXIT6" -eq 2 ] && printf '%s' "$OUT6" | grep -q '"decision":"block"'; then
  pass "E6. Layer 2: CONFIRM_OUTLINE + no follow-up Skill → block (exit 2 + decision:block)"
else
  fail "E6. expected exit 2 + decision:block; got exit=$EXIT6 out=$OUT6"
fi

# --- E7: Layer 2 — CONFIRM_OUTLINE + valid make-detail-plan Skill → pass ------
arm_marker
T7="$TMP/t7.jsonl"
node -e '
  const fs = require("fs");
  const out = process.argv[1];
  const entry = { type: "assistant", message: { content: [
    { type: "tool_use", name: "Bash",
      input: { command: "echo \"<<WORKFLOW_CONFIRM_OUTLINE: outline confirmed>>\""} },
    { type: "tool_use", name: "Skill", input: { skill: "make-detail-plan" } },
  ] } };
  fs.writeFileSync(out, JSON.stringify(entry) + "\n", "utf8");
' "$T7"
set +e
OUT7="$(run_hook "$T7")"; EXIT7=$?
set -e
if [ "$EXIT7" -eq 0 ]; then
  pass "E7. Layer 2: CONFIRM_OUTLINE + valid make-detail-plan Skill → pass (exit 0)"
else
  fail "E7. expected exit 0 (pass); got exit=$EXIT7 out=$OUT7"
fi

# --- E8: Layer 2 — CONFIRM_DETAIL + no follow-up → block ----------------------
arm_marker
T8="$TMP/t8.jsonl"
node -e '
  const fs = require("fs");
  const out = process.argv[1];
  const entry = { type: "assistant", message: { content: [
    { type: "tool_use", name: "Bash",
      input: { command: "echo \"<<WORKFLOW_CONFIRM_DETAIL: detail confirmed>>\""} },
  ] } };
  fs.writeFileSync(out, JSON.stringify(entry) + "\n", "utf8");
' "$T8"
set +e
OUT8="$(run_hook "$T8")"; EXIT8=$?
set -e
if [ "$EXIT8" -eq 2 ] && printf '%s' "$OUT8" | grep -q '"decision":"block"'; then
  pass "E8. Layer 2: CONFIRM_DETAIL + no follow-up → block (exit 2 + decision:block)"
else
  fail "E8. expected exit 2 + decision:block; got exit=$EXIT8 out=$OUT8"
fi

# --- E9: Layer 2 — CONFIRM_DETAIL + WORKFLOW_BRANCHING_COMPLETE Bash → pass ---
arm_marker
T9="$TMP/t9.jsonl"
node -e '
  const fs = require("fs");
  const out = process.argv[1];
  const entry = { type: "assistant", message: { content: [
    { type: "tool_use", name: "Bash",
      input: { command: "echo \"<<WORKFLOW_CONFIRM_DETAIL: detail confirmed>>\""} },
    { type: "tool_use", name: "Bash",
      input: { command: "echo \"<<WORKFLOW_BRANCHING_COMPLETE: branch: feature/x|worktree: /path|main>>\""} },
  ] } };
  fs.writeFileSync(out, JSON.stringify(entry) + "\n", "utf8");
' "$T9"
set +e
OUT9="$(run_hook "$T9")"; EXIT9=$?
set -e
if [ "$EXIT9" -eq 0 ]; then
  pass "E9. Layer 2: CONFIRM_DETAIL + WORKFLOW_BRANCHING_COMPLETE → pass (exit 0)"
else
  fail "E9. expected exit 0 (pass); got exit=$EXIT9 out=$OUT9"
fi

# --- E10: stop_hook_active=true fast-exit (guard against infinite re-blocking) -
# Even with marker + path present, stop_hook_active=true must bypass all guards.
arm_marker
T10="$TMP/t10.jsonl"
make_transcript "The plan lives at $PLANS_PATH — open it." "$T10"
set +e
OUT10="$(printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"transcript_path\":\"$T10\",\"stop_hook_active\":true}" \
  | node "$HOOK")"; EXIT10=$?
set -e
if [ "$EXIT10" -eq 0 ]; then
  pass "E10. stop_hook_active=true → fast-exit (exit 0, no block)"
else
  fail "E10. stop_hook_active=true should short-circuit; got exit=$EXIT10 out=$OUT10"
fi

# --- E11: Layer 2 — CONFIRM_DETAIL + write-tests Skill follow-up → pass (CPR-5)
# The detail stage has two valid follow-up paths: WORKFLOW_BRANCHING_COMPLETE (E9)
# and a Skill tool_use with "write-tests" (this test). Both must allow the turn.
arm_marker
T11="$TMP/t11.jsonl"
node -e '
  const fs = require("fs");
  const out = process.argv[1];
  const entry = { type: "assistant", message: { content: [
    { type: "tool_use", name: "Bash",
      input: { command: "echo \"<<WORKFLOW_CONFIRM_DETAIL: detail confirmed>>\""} },
    { type: "tool_use", name: "Skill", input: { skill: "write-tests" } },
  ] } };
  fs.writeFileSync(out, JSON.stringify(entry) + "\n", "utf8");
' "$T11"
set +e
OUT11="$(run_hook "$T11")"; EXIT11=$?
set -e
if [ "$EXIT11" -eq 0 ]; then
  pass "E11. Layer 2: CONFIRM_DETAIL + write-tests Skill → pass (exit 0)"
else
  fail "E11. expected exit 0 for write-tests follow-up; got exit=$EXIT11 out=$OUT11"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
