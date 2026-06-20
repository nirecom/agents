#!/usr/bin/env bash
# Tests: skills/_shared/assemble-mandatory.sh, hooks/show-diff.js, bin/run-codex-review-loop, skills/_shared/codex-review-loop.md
# Tags: workflow, plans, hook, bin, env, scope:issue-specific
#
# Issue #866 — remove drafts/ subdirectory from ~/.workflow-plans/.
# After this change, all intermediate plan artifacts live directly under
# PLANS_DIR root, distinguished by filename suffix instead of directory.
# assemble-mandatory.sh moves to in-place overwrite mode (arg 2 == arg 3).
# show-diff.js switches from path-prefix suppression (`drafts/`) to
# filename-suffix pattern matching via INTERMEDIATE_PATTERNS.
#
# L3 gap (what this test does NOT catch):
# - Real make-outline-plan/make-detail-plan orchestration with actual codex calls
# - Live show-diff.js hook firing inside a real Claude Code session
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/show-diff.js"
ASSEMBLE="$AGENTS_DIR/skills/_shared/assemble-mandatory.sh"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

# Resolve Node-visible tmp dir for hook tests (so isUnderPath matches)
NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"

# Isolated empty cfg dir so loadDefaultEnv() does not leak CONFIRM_* values.
ISOLATED_CFG_DIR="${NODE_TMPDIR}/f866-cfg-$$"
mkdir -p "$ISOLATED_CFG_DIR"

# Per-test PLANS_DIR (sandboxed under tmpdir; the hook resolves WORKFLOW_PLANS_DIR)
PLANS_DIR="${NODE_TMPDIR}/f866-plans-$$"
mkdir -p "$PLANS_DIR"

cleanup() { rm -rf "$ISOLATED_CFG_DIR" "$PLANS_DIR"; }
trap cleanup EXIT

export WORKFLOW_PLANS_DIR="$PLANS_DIR"
export AGENTS_CONFIG_DIR="$ISOLATED_CFG_DIR"
unset CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true

run_hook() {
  local json="$1"
  echo "$json" | run_with_timeout node "$HOOK" 2>/dev/null
}

expect_empty() {
  local desc="$1" json="$2"
  local result
  result=$(run_hook "$json")
  if [ -z "$result" ]; then
    pass "$desc"
  else
    fail "$desc — expected empty stdout, got: $result"
  fi
}

expect_nonempty() {
  local desc="$1" json="$2"
  local result
  result=$(run_hook "$json")
  if [ -n "$result" ]; then
    pass "$desc"
  else
    fail "$desc — expected non-empty stdout (diff), got empty"
  fi
}

# ============================================================================
# T1 — assemble-mandatory.sh in-place mode (intent → outline overwrite)
# ============================================================================
T1_PLANS="${NODE_TMPDIR}/f866-t1-$$"
mkdir -p "$T1_PLANS"

# Source: intent.md with all three mandatory sections
cat > "$T1_PLANS/20260620-TEST-intent.md" << 'EOF'
# Test Intent

Some intro.

## Issues

- #866

## Class members

- member-a
- member-b

## Accepted Tradeoffs

- tradeoff-a
EOF

# Planner output (initial outline at the target path — in-place mode overwrites it).
# Body must start with a ## header so extract-mandatory-sections stops at the
# first planner section boundary rather than absorbing plain text into the last
# mandatory section's body.
cat > "$T1_PLANS/20260620-TEST-outline.md" << 'EOF'
# Planner-Produced Outline

## Adopted approach

Some approach detail.
EOF

# In-place: arg 2 == arg 3
T1_RC=0
bash "$ASSEMBLE" --source-kind intent \
  "$T1_PLANS/20260620-TEST-intent.md" \
  "$T1_PLANS/20260620-TEST-outline.md" \
  "$T1_PLANS/20260620-TEST-outline.md" \
  > "$T1_PLANS/t1.stdout" 2> "$T1_PLANS/t1.stderr" || T1_RC=$?

if [[ $T1_RC -eq 0 ]]; then
  pass "T1 in-place assemble (intent → outline) exits 0"
else
  fail "T1 in-place assemble exited $T1_RC. stderr: $(cat "$T1_PLANS/t1.stderr")"
fi

if grep -qF "## Issues" "$T1_PLANS/20260620-TEST-outline.md" \
   && grep -qF "## Class members" "$T1_PLANS/20260620-TEST-outline.md" \
   && grep -qF "## Accepted Tradeoffs" "$T1_PLANS/20260620-TEST-outline.md"; then
  pass "T1 output contains all 3 mandatory sections from intent"
else
  fail "T1 mandatory sections missing from output"
fi

if grep -qF "Planner-Produced Outline" "$T1_PLANS/20260620-TEST-outline.md"; then
  pass "T1 output preserves planner H1 (sole H1 — original H1 of intent stripped per algorithm)"
else
  fail "T1 H1 stripped — output does not contain planner H1"
fi

rm -rf "$T1_PLANS"

# ============================================================================
# T2 — assemble-mandatory.sh in-place soft-fail
# (source-kind intent, missing ## Class members → stub injected)
# ============================================================================
T2_PLANS="${NODE_TMPDIR}/f866-t2-$$"
mkdir -p "$T2_PLANS"

cat > "$T2_PLANS/20260620-TEST-intent.md" << 'EOF'
# Test Intent (legacy, pre-#462)

## Issues

- #866

## Accepted Tradeoffs

- t-only
EOF

cat > "$T2_PLANS/20260620-TEST-outline.md" << 'EOF'
# Planner Outline

## Adopted approach

Body content here.
EOF

T2_RC=0
bash "$ASSEMBLE" --source-kind intent \
  "$T2_PLANS/20260620-TEST-intent.md" \
  "$T2_PLANS/20260620-TEST-outline.md" \
  "$T2_PLANS/20260620-TEST-outline.md" \
  > "$T2_PLANS/t2.stdout" 2> "$T2_PLANS/t2.stderr" || T2_RC=$?

if [[ $T2_RC -eq 0 ]]; then
  pass "T2 in-place soft-fail (intent, missing Class members) exits 0"
else
  fail "T2 expected exit 0 (soft-fail with stub), got $T2_RC. stderr: $(cat "$T2_PLANS/t2.stderr")"
fi

rm -rf "$T2_PLANS"

# ============================================================================
# T3 — assemble-mandatory.sh in-place hard-fail
# (source-kind outline, missing ## Class members → exit non-zero)
# ============================================================================
T3_PLANS="${NODE_TMPDIR}/f866-t3-$$"
mkdir -p "$T3_PLANS"

cat > "$T3_PLANS/20260620-TEST-outline.md" << 'EOF'
# Outline as Source

## Issues

- #866

## Accepted Tradeoffs

- t-only
EOF

cat > "$T3_PLANS/20260620-TEST-detail.md" << 'EOF'
# Planner Detail

Body without mandatory sections.
EOF

T3_RC=0
bash "$ASSEMBLE" --source-kind outline \
  "$T3_PLANS/20260620-TEST-outline.md" \
  "$T3_PLANS/20260620-TEST-detail.md" \
  "$T3_PLANS/20260620-TEST-detail.md" \
  > "$T3_PLANS/t3.stdout" 2> "$T3_PLANS/t3.stderr" || T3_RC=$?

if [[ $T3_RC -ne 0 ]]; then
  pass "T3 in-place hard-fail (outline, missing Class members) exits non-zero ($T3_RC)"
else
  fail "T3 expected non-zero exit (hard-fail), got 0"
fi

rm -rf "$T3_PLANS"

# ============================================================================
# T4 — show-diff.js suppresses all intermediate suffix patterns
# (PLANS_DIR-root flat paths)
# ============================================================================
INTERMEDIATE_PATTERNS=(
  "20260620-TEST-outline-draft.md"
  "20260620-TEST-detail-draft.md"
  "20260620-TEST-codex-round-1-raw.md"
  "20260620-TEST-outline-codex-round-1-raw.md"
  "20260620-TEST-concerns-log.md"
  "20260620-TEST-outline-concerns-log.md"
  "20260620-TEST-debug.log"
  "20260620-TEST-outline-plan-round-number.txt"
  "20260620-TEST-detail-plan-round-number.txt"
  "20260620-TEST-outline-plan-concern-ledger.txt"
  "20260620-TEST-detail-plan-concern-ledger.txt"
  "20260620-TEST-outline-plan-concern-ledger-cap-snapshot.txt"
  "20260620-TEST-codex-context.md"
  "20260620-TEST-codex-context.outline-plan.built"
  "20260620-TEST-codex-context.detail-plan.built"
  "20260620-TEST-plan.jsonl"
  "20260620-TEST-issue-prefill.md"
  "20260620-TEST-workflow-init-aborted-pathA-multiN-label-failure.md"
  "20260620-TEST-guard-attempt.tmp"
)

for pat in "${INTERMEDIATE_PATTERNS[@]}"; do
  expect_empty "T4 intermediate pattern suppressed: $pat" \
    "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/$pat\",\"content\":\"x\"}}"
done

# ============================================================================
# T5 — show-diff.js does NOT suppress <sid>-context.md (WI-9 session-context)
# ============================================================================
expect_nonempty "T5 <sid>-context.md NOT suppressed (session-context final artifact)" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/20260620-TEST-context.md\",\"content\":\"x\"}}"

# ============================================================================
# T6 — show-diff.js does NOT suppress final artifact (outline.md)
# ============================================================================
expect_nonempty "T6 final outline.md artifact NOT suppressed" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/20260620-TEST-outline.md\",\"content\":\"x\"}}"

# ============================================================================
# T7 — no drafts/ directory created by assemble-mandatory in-place mode
# ============================================================================
T7_PLANS="${NODE_TMPDIR}/f866-t7-$$"
mkdir -p "$T7_PLANS"

cat > "$T7_PLANS/20260620-TEST-intent.md" << 'EOF'
# Intent

## Issues

- #866

## Class members

- a

## Accepted Tradeoffs

- t
EOF

cat > "$T7_PLANS/20260620-TEST-outline.md" << 'EOF'
# Planner Outline

Body.
EOF

bash "$ASSEMBLE" --source-kind intent \
  "$T7_PLANS/20260620-TEST-intent.md" \
  "$T7_PLANS/20260620-TEST-outline.md" \
  "$T7_PLANS/20260620-TEST-outline.md" \
  >/dev/null 2>&1 || true

if [[ ! -d "$T7_PLANS/drafts" ]]; then
  pass "T7 assemble-mandatory in-place did NOT create $T7_PLANS/drafts/"
else
  fail "T7 assemble-mandatory created drafts/ dir unexpectedly"
fi

rm -rf "$T7_PLANS"

# ============================================================================
# Results
# ============================================================================
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed"
  exit 1
fi
