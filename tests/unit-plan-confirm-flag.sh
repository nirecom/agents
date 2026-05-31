#!/usr/bin/env bash
# Tests: hooks/lib/plan-confirm-flag.js
# Tags: plan-confirm-flag
# Unit tests for hooks/lib/plan-confirm-flag.js
#
# Tests getSuffix, getConfirmFlagName, and isConfirmOff in isolation by
# requiring the module via `node -e` with WORKFLOW_PLANS_DIR set to a
# per-run temp directory.
set -uo pipefail

# Use `pwd -W` on Windows (MSYS2/Git Bash) to get a Windows-form path that
# Node.js can resolve when embedded inside `node -e` script strings. Falls
# back to plain `pwd` on POSIX where `-W` is unsupported.
AGENTS_DIR="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
LIB="$AGENTS_DIR/hooks/lib/plan-confirm-flag.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout wrapper (rules/test-rules/macos-timeout.md)
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

# Per-run temp plans dir (matches the form Node sees on Windows).
NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
PLANS_DIR="${NODE_TMPDIR}/pcf-test-$$"
mkdir -p "$PLANS_DIR"

# Isolated AGENTS_CONFIG_DIR with NO .env file — workflow-plans-dir lazily
# calls loadDefaultEnv() on first access; with AGENTS_CONFIG_DIR pointing to
# an empty dir, no real .env is read and CONFIRM_* defaults stay clean.
ISOLATED_CFG_DIR="${NODE_TMPDIR}/pcf-cfg-$$"
mkdir -p "$ISOLATED_CFG_DIR"
export AGENTS_CONFIG_DIR="$ISOLATED_CFG_DIR"

trap 'rm -rf "$PLANS_DIR" "$ISOLATED_CFG_DIR"' EXIT

# Unset CONFIRM_* so they don't bleed in from the parent shell.
unset CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true

# Helper: run a node snippet that evaluates a single library call and prints
# the stringified result. Env vars passed as inline `KEY=val` assignments
# before the node command (applied via a subshell `export`).
# $1 = description, $2 = expected, $3 = node expression, $4... = env assignments
expect_result() {
  local desc="$1" expected="$2" expr="$3"
  shift 3
  local result
  result=$(
    export WORKFLOW_PLANS_DIR="$PLANS_DIR"
    # Apply each KEY=VAL argument as an export in this subshell.
    for assignment in "$@"; do
      # Split on first '=' only — value may contain spaces or further '='.
      key="${assignment%%=*}"
      val="${assignment#*=}"
      export "$key=$val"
    done
    run_with_timeout node -e "
      const lib = require('$LIB');
      const v = $expr;
      process.stdout.write(String(v));
    " 2>&1
  )
  if [ "$result" = "$expected" ]; then
    pass "$desc"
  else
    fail "$desc — expected '$expected', got '$result'"
  fi
}

# ══════════════════════════════════════════════════════════════════════════
# getSuffix tests
# ══════════════════════════════════════════════════════════════════════════

echo "=== getSuffix tests ==="

# T1: *-intent.md → "intent"
expect_result "T1 getSuffix abc-intent.md → 'intent'" "intent" \
  "lib.getSuffix('$PLANS_DIR/abc-intent.md')"

# T2: *-outline.md → "outline"
expect_result "T2 getSuffix abc-outline.md → 'outline'" "outline" \
  "lib.getSuffix('$PLANS_DIR/abc-outline.md')"

# T3: *-detail.md → "detail"
expect_result "T3 getSuffix abc-detail.md → 'detail'" "detail" \
  "lib.getSuffix('$PLANS_DIR/abc-detail.md')"

# T4: *-context.md → null
expect_result "T4 getSuffix abc-context.md → null" "null" \
  "lib.getSuffix('$PLANS_DIR/abc-context.md')"

# T5: intent.md (no prefix) → null
expect_result "T5 getSuffix intent.md (no prefix) → null" "null" \
  "lib.getSuffix('$PLANS_DIR/intent.md')"

# T6: uppercase suffix → null (case-sensitive)
expect_result "T6 getSuffix abc-DETAIL.md (uppercase) → null" "null" \
  "lib.getSuffix('$PLANS_DIR/abc-DETAIL.md')"

# T7: drafts/ subdir → null (not direct child)
expect_result "T7 getSuffix drafts/abc-detail.md → null" "null" \
  "lib.getSuffix('$PLANS_DIR/drafts/abc-detail.md')"

# T8: empty string → null
expect_result "T8 getSuffix '' → null" "null" \
  "lib.getSuffix('')"

# ══════════════════════════════════════════════════════════════════════════
# getConfirmFlagName tests
# ══════════════════════════════════════════════════════════════════════════

echo "=== getConfirmFlagName tests ==="

# T9: "intent" → "CONFIRM_INTENT"
expect_result "T9 getConfirmFlagName 'intent' → 'CONFIRM_INTENT'" "CONFIRM_INTENT" \
  "lib.getConfirmFlagName('intent')"

# T10: "outline" → "CONFIRM_OUTLINE"
expect_result "T10 getConfirmFlagName 'outline' → 'CONFIRM_OUTLINE'" "CONFIRM_OUTLINE" \
  "lib.getConfirmFlagName('outline')"

# T11: "detail" → "CONFIRM_DETAIL"
expect_result "T11 getConfirmFlagName 'detail' → 'CONFIRM_DETAIL'" "CONFIRM_DETAIL" \
  "lib.getConfirmFlagName('detail')"

# T12: null → null
expect_result "T12 getConfirmFlagName null → null" "null" \
  "lib.getConfirmFlagName(null)"

# T13: "bogus" → null
expect_result "T13 getConfirmFlagName 'bogus' → null" "null" \
  "lib.getConfirmFlagName('bogus')"

# ══════════════════════════════════════════════════════════════════════════
# isConfirmOff tests
# ══════════════════════════════════════════════════════════════════════════

echo "=== isConfirmOff tests ==="

# T14: CONFIRM_DETAIL=off → true
expect_result "T14 isConfirmOff CONFIRM_DETAIL=off detail.md → true" "true" \
  "lib.isConfirmOff('$PLANS_DIR/abc-detail.md')" \
  CONFIRM_DETAIL=off

# T15: CONFIRM_DETAIL=OFF → true (case-insensitive)
expect_result "T15 isConfirmOff CONFIRM_DETAIL=OFF detail.md → true" "true" \
  "lib.isConfirmOff('$PLANS_DIR/abc-detail.md')" \
  CONFIRM_DETAIL=OFF

# T16: CONFIRM_DETAIL=Off → true
expect_result "T16 isConfirmOff CONFIRM_DETAIL=Off detail.md → true" "true" \
  "lib.isConfirmOff('$PLANS_DIR/abc-detail.md')" \
  CONFIRM_DETAIL=Off

# T17: CONFIRM_DETAIL=0 → true
expect_result "T17 isConfirmOff CONFIRM_DETAIL=0 detail.md → true" "true" \
  "lib.isConfirmOff('$PLANS_DIR/abc-detail.md')" \
  CONFIRM_DETAIL=0

# T18: CONFIRM_DETAIL=false → true
expect_result "T18 isConfirmOff CONFIRM_DETAIL=false detail.md → true" "true" \
  "lib.isConfirmOff('$PLANS_DIR/abc-detail.md')" \
  CONFIRM_DETAIL=false

# T19: CONFIRM_DETAIL=no → true
expect_result "T19 isConfirmOff CONFIRM_DETAIL=no detail.md → true" "true" \
  "lib.isConfirmOff('$PLANS_DIR/abc-detail.md')" \
  CONFIRM_DETAIL=no

# T20: CONFIRM_DETAIL=disabled → true
expect_result "T20 isConfirmOff CONFIRM_DETAIL=disabled detail.md → true" "true" \
  "lib.isConfirmOff('$PLANS_DIR/abc-detail.md')" \
  CONFIRM_DETAIL=disabled

# T21: CONFIRM_DETAIL=on → false
expect_result "T21 isConfirmOff CONFIRM_DETAIL=on detail.md → false" "false" \
  "lib.isConfirmOff('$PLANS_DIR/abc-detail.md')" \
  CONFIRM_DETAIL=on

# T22: CONFIRM_DETAIL unset → false
expect_result "T22 isConfirmOff CONFIRM_DETAIL unset detail.md → false" "false" \
  "lib.isConfirmOff('$PLANS_DIR/abc-detail.md')"

# T23: CONFIRM_DETAIL=off on context.md → false (not a plan suffix)
expect_result "T23 isConfirmOff CONFIRM_DETAIL=off context.md → false" "false" \
  "lib.isConfirmOff('$PLANS_DIR/abc-context.md')" \
  CONFIRM_DETAIL=off

# T24: CONFIRM_DETAIL=off on drafts/ child → false (not direct child)
expect_result "T24 isConfirmOff CONFIRM_DETAIL=off drafts/detail.md → false" "false" \
  "lib.isConfirmOff('$PLANS_DIR/drafts/abc-detail.md')" \
  CONFIRM_DETAIL=off

# T25: CONFIRM_DETAIL="  off" (padded) → false (fail-safe: whitespace → ON)
expect_result "T25 isConfirmOff CONFIRM_DETAIL='  off' detail.md → false" "false" \
  "lib.isConfirmOff('$PLANS_DIR/abc-detail.md')" \
  "CONFIRM_DETAIL=  off"

# T26: CONFIRM_INTENT=off on detail.md → false (cross-suffix non-leakage)
expect_result "T26 isConfirmOff CONFIRM_INTENT=off detail.md → false" "false" \
  "lib.isConfirmOff('$PLANS_DIR/abc-detail.md')" \
  CONFIRM_INTENT=off

# ── Results ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed"
  exit 1
fi
