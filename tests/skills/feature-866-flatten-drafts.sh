#!/usr/bin/env bash
# Tests: skills/_shared/assemble-mandatory.sh, bin/run-codex-review-loop, skills/_shared/codex-review-loop.md
# Tags: workflow, plans, hook, bin, env, scope:issue-specific
# Issue #866 — plan intermediates live flat under PLANS_DIR, told apart by filename suffix; contract: assemble-mandatory.sh header.
# L3 gap (real planner orchestration): bin/check-verification-gate.sh category skill-orchestration.
set -uo pipefail

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSEMBLE="$SCRIPT_CHECKOUT_ROOT/skills/_shared/assemble-mandatory.sh"
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

cleanup() { rm -rf "$ISOLATED_CFG_DIR"; }
trap cleanup EXIT

export AGENTS_MAIN_ROOT="$ISOLATED_CFG_DIR"
unset CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true

# T1 — assemble-mandatory.sh in-place mode (intent → outline overwrite)
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

# Planner output at the target path; the body starts with a ## header so the extractor stops at the first planner section.
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
   && ! grep -qF "## Class members" "$T1_PLANS/20260620-TEST-outline.md" \
   && grep -qF "## Accepted Tradeoffs" "$T1_PLANS/20260620-TEST-outline.md"; then
  pass "T1 output contains Issues and Accepted Tradeoffs from intent; Class members is not injected (#2228)"
else
  fail "T1 mandatory sections missing from output"
fi

if grep -qF "Planner-Produced Outline" "$T1_PLANS/20260620-TEST-outline.md"; then
  pass "T1 output preserves planner H1 (sole H1 — original H1 of intent stripped per algorithm)"
else
  fail "T1 H1 stripped — output does not contain planner H1"
fi

rm -rf "$T1_PLANS"

# T2 — in-place hard-fail: intent without ## Class members fails the outline coverage gate (exit 4; no stub since #2228)
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

if [[ $T2_RC -eq 4 ]]; then
  pass "T2 in-place hard-fail (intent, missing Class members) exits 4"
else
  fail "T2 expected exit 4 (coverage gate hard-fail), got $T2_RC. stderr: $(cat "$T2_PLANS/t2.stderr")"
fi

if grep -qF "GATE FAIL" "$T2_PLANS/t2.stderr"; then
  pass "T2 stderr reports GATE FAIL (intent, missing Class members)"
else
  fail "T2 expected GATE FAIL on stderr, got: $(cat "$T2_PLANS/t2.stderr")"
fi

rm -rf "$T2_PLANS"

# T3 — in-place hard-fail: outline source without ## Class members exits non-zero
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

# T4-T6 removed in #2592

# T7 — no drafts/ directory created by assemble-mandatory in-place mode
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

## Adopted approach

Body.
EOF

T7_RC=0
bash "$ASSEMBLE" --source-kind intent \
  "$T7_PLANS/20260620-TEST-intent.md" \
  "$T7_PLANS/20260620-TEST-outline.md" \
  "$T7_PLANS/20260620-TEST-outline.md" \
  >/dev/null 2>&1 || T7_RC=$?

if [[ $T7_RC -ne 0 ]]; then
  fail "T7 assemble-mandatory in-place exited non-zero ($T7_RC)"
elif [[ ! -d "$T7_PLANS/drafts" ]]; then
  pass "T7 assemble-mandatory in-place did NOT create $T7_PLANS/drafts/"
else
  fail "T7 assemble-mandatory created drafts/ dir unexpectedly"
fi

rm -rf "$T7_PLANS"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed"
  exit 1
fi
