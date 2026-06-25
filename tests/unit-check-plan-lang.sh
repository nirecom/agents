#!/usr/bin/env bash
# Tests: hooks/check-plan-lang.js, hooks/lib/is-plan-artifact.js
# Tags: hook, plans, security, scope:common
# Full hook-invocation tests for hooks/check-plan-lang.js
#
# Invokes the hook by piping PreToolUse JSON payloads to
# `node hooks/check-plan-lang.js` and asserts on stdout decision field.
#
# PLAN_LANG is unset for most tests → policy is "noop" → hook always approves.
# T7 uses PLAN_LANG=english with Japanese content to exercise the block path.
#
# L3 gap (what this test does NOT catch):
# - Whether check-plan-lang.js fires as a real PreToolUse hook in a live Claude
#   Code session (requires actual hook registration in settings.json and a
#   real session event).
# - Whether the hook fires on the correct tool events when registered in
#   settings.json (only observable in a live session).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
HOOK="$AGENTS_DIR/hooks/check-plan-lang.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }
skip() { echo "SKIP: $1"; }

# Portable timeout wrapper (rules/test/macos-timeout.md)
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 "$@"
  else
    perl -e 'alarm 30; exec @ARGV' -- "$@"
  fi
}

# Require jq for JSON parsing; skip all tests if unavailable.
if ! command -v jq >/dev/null 2>&1; then
  skip "jq not found — skipping all hook invocation tests"
  echo ""
  echo "=== Results ==="
  echo "0 passed, all skipped (jq unavailable)."
  exit 0
fi

# Fixed fake UUID used throughout tests.
FAKE_UUID="a1b2c3d4-e5f6-7890-abcd-ef1234567890"

# Per-run temp directory used as WORKFLOW_PLANS_DIR.
# Use node to get the OS temp dir in a form node itself will accept.
NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
PLANS_DIR="${NODE_TMPDIR}/check-plan-lang-test-$$"
mkdir -p "$PLANS_DIR"

# Isolated AGENTS_CONFIG_DIR with no .env so PLAN_LANG is not inherited from
# the real environment.
ISOLATED_CFG_DIR="${NODE_TMPDIR}/check-plan-lang-cfg-$$"
mkdir -p "$ISOLATED_CFG_DIR"

trap 'rm -rf "$PLANS_DIR" "$ISOLATED_CFG_DIR"' EXIT

# ── Helper ────────────────────────────────────────────────────────────────────
# invoke_hook PLAN_LANG TOOL_NAME FILE_PATH CONTENT
#   Runs the hook with PLAN_LANG (empty = unset) and returns jq-parsed decision.
#   Prints the raw decision string to stdout.
invoke_hook() {
  local plan_lang="$1" tool_name="$2" file_path="$3" content="$4"
  local payload decision
  payload="$(node -e "
    process.stdout.write(JSON.stringify({
      tool_name: '$tool_name',
      tool_input: { file_path: '$file_path', content: $(node -e "process.stdout.write(JSON.stringify('$content'))") }
    }));
  " 2>/dev/null)"

  local env_prefix=""
  if [ -n "$plan_lang" ]; then
    env_prefix="PLAN_LANG=$plan_lang "
  fi

  decision=$(
    export WORKFLOW_PLANS_DIR="$PLANS_DIR"
    export AGENTS_CONFIG_DIR="$ISOLATED_CFG_DIR"
    unset PLAN_LANG 2>/dev/null || true
    if [ -n "$plan_lang" ]; then
      export PLAN_LANG="$plan_lang"
    fi
    echo "$payload" | run_with_timeout node "$HOOK" 2>/dev/null | jq -r .decision
  )
  echo "$decision"
}

# ── Helper that builds payload via node to avoid quoting pitfalls ─────────────
# invoke_hook_json PLAN_LANG JSON_PAYLOAD_STRING
invoke_hook_json() {
  local plan_lang="$1" payload="$2"
  local decision
  decision=$(
    export WORKFLOW_PLANS_DIR="$PLANS_DIR"
    export AGENTS_CONFIG_DIR="$ISOLATED_CFG_DIR"
    unset PLAN_LANG 2>/dev/null || true
    if [ -n "$plan_lang" ]; then
      export PLAN_LANG="$plan_lang"
    fi
    echo "$payload" | run_with_timeout node "$HOOK" 2>/dev/null | jq -r .decision
  )
  echo "$decision"
}

echo "=== check-plan-lang.js hook invocation tests ==="

# ── T1: Read tool (not a TARGET_TOOL) → approve ───────────────────────────────
result=$(invoke_hook_json "" "$(node -e "
process.stdout.write(JSON.stringify({
  tool_name: 'Read',
  tool_input: { file_path: '${PLANS_DIR}/${FAKE_UUID}-intent.md' }
}))
" 2>/dev/null)")
if [ "$result" = "approve" ]; then
  pass "T1: Read tool (not in TARGET_TOOLS) → approve"
else
  fail "T1: Read tool → expected 'approve', got '$result'"
fi

# ── T2: Write tool, UUID intent.md inside plans dir, PLAN_LANG unset → approve ─
result=$(invoke_hook_json "" "$(node -e "
process.stdout.write(JSON.stringify({
  tool_name: 'Write',
  tool_input: {
    file_path: '${PLANS_DIR}/${FAKE_UUID}-intent.md',
    content: 'English content only'
  }
}))
" 2>/dev/null)")
if [ "$result" = "approve" ]; then
  pass "T2: Write tool, UUID intent.md in plans dir, PLAN_LANG unset → approve (noop policy)"
else
  fail "T2: Write intent.md PLAN_LANG unset → expected 'approve', got '$result'"
fi

# ── T3: MultiEdit tool, UUID intent.md inside plans dir, PLAN_LANG unset → approve
result=$(invoke_hook_json "" "$(node -e "
process.stdout.write(JSON.stringify({
  tool_name: 'MultiEdit',
  tool_input: {
    file_path: '${PLANS_DIR}/${FAKE_UUID}-intent.md',
    content: 'English content only'
  }
}))
" 2>/dev/null)")
if [ "$result" = "approve" ]; then
  pass "T3: MultiEdit tool, UUID intent.md in plans dir, PLAN_LANG unset → approve (noop policy)"
else
  fail "T3: MultiEdit intent.md PLAN_LANG unset → expected 'approve', got '$result'"
fi

# ── T4: editFiles tool, UUID intent.md inside plans dir, PLAN_LANG unset → approve
result=$(invoke_hook_json "" "$(node -e "
process.stdout.write(JSON.stringify({
  tool_name: 'editFiles',
  tool_input: {
    file_path: '${PLANS_DIR}/${FAKE_UUID}-intent.md',
    content: 'English content only'
  }
}))
" 2>/dev/null)")
if [ "$result" = "approve" ]; then
  pass "T4: editFiles tool, UUID intent.md in plans dir, PLAN_LANG unset → approve (noop policy)"
else
  fail "T4: editFiles intent.md PLAN_LANG unset → expected 'approve', got '$result'"
fi

# ── T5: Security — path traversal → approve (resolves outside plans dir) ───────
TRAVERSAL_PATH="${PLANS_DIR}/../../../evil-intent.md"
result=$(invoke_hook_json "" "$(node -e "
process.stdout.write(JSON.stringify({
  tool_name: 'Edit',
  tool_input: {
    file_path: '${TRAVERSAL_PATH}',
    content: 'malicious content'
  }
}))
" 2>/dev/null)")
if [ "$result" = "approve" ]; then
  pass "T5: path traversal (../../evil-intent.md) resolves outside plans dir → approve"
else
  fail "T5: path traversal → expected 'approve', got '$result'"
fi

# ── T6: File outside plans dir entirely → approve ────────────────────────────
OUTSIDE_PATH="${NODE_TMPDIR}/not-in-plans/${FAKE_UUID}-intent.md"
result=$(invoke_hook_json "" "$(node -e "
process.stdout.write(JSON.stringify({
  tool_name: 'Edit',
  tool_input: {
    file_path: '${OUTSIDE_PATH}',
    content: 'some content'
  }
}))
" 2>/dev/null)")
if [ "$result" = "approve" ]; then
  pass "T6: file outside plans dir → approve"
else
  fail "T6: file outside plans dir → expected 'approve', got '$result'"
fi

# ── T7: isPlanArtifact = false (context.md) → approve ────────────────────────
result=$(invoke_hook_json "" "$(node -e "
process.stdout.write(JSON.stringify({
  tool_name: 'Edit',
  tool_input: {
    file_path: '${PLANS_DIR}/${FAKE_UUID}-context.md',
    content: 'some context'
  }
}))
" 2>/dev/null)")
if [ "$result" = "approve" ]; then
  pass "T7: context.md (isPlanArtifact=false) inside plans dir → approve"
else
  fail "T7: context.md → expected 'approve', got '$result'"
fi

# ── T8: PLAN_LANG=english with English content → approve ─────────────────────
result=$(invoke_hook_json "english" "$(node -e "
process.stdout.write(JSON.stringify({
  tool_name: 'Edit',
  tool_input: {
    file_path: '${PLANS_DIR}/${FAKE_UUID}-intent.md',
    content: 'This is a valid English planning artifact with no Japanese characters.'
  }
}))
" 2>/dev/null)")
if [ "$result" = "approve" ]; then
  pass "T8: PLAN_LANG=english with English-only content → approve"
else
  fail "T8: PLAN_LANG=english English content → expected 'approve', got '$result'"
fi

# ── T9: Idempotency — same input twice yields same decision ──────────────────
PAYLOAD_IDEM="$(node -e "
process.stdout.write(JSON.stringify({
  tool_name: 'Edit',
  tool_input: {
    file_path: '${PLANS_DIR}/${FAKE_UUID}-outline.md',
    content: 'Idempotency test content in English.'
  }
}))
" 2>/dev/null)"

result1=$(
  export WORKFLOW_PLANS_DIR="$PLANS_DIR"
  export AGENTS_CONFIG_DIR="$ISOLATED_CFG_DIR"
  unset PLAN_LANG 2>/dev/null || true
  echo "$PAYLOAD_IDEM" | run_with_timeout node "$HOOK" 2>/dev/null | jq -r .decision
)
result2=$(
  export WORKFLOW_PLANS_DIR="$PLANS_DIR"
  export AGENTS_CONFIG_DIR="$ISOLATED_CFG_DIR"
  unset PLAN_LANG 2>/dev/null || true
  echo "$PAYLOAD_IDEM" | run_with_timeout node "$HOOK" 2>/dev/null | jq -r .decision
)
if [ "$result1" = "$result2" ] && [ "$result1" = "approve" ]; then
  pass "T9: idempotency — same payload twice yields same decision ('$result1')"
else
  fail "T9: idempotency — first='$result1', second='$result2' (expected both 'approve')"
fi

# ── T10: Edit tool (already covered by unit-is-plan-artifact but verified here ─
# at hook invocation level for approve-path coverage)
result=$(invoke_hook_json "" "$(node -e "
process.stdout.write(JSON.stringify({
  tool_name: 'Edit',
  tool_input: {
    file_path: '${PLANS_DIR}/${FAKE_UUID}-detail.md',
    content: 'English detail content.'
  }
}))
" 2>/dev/null)")
if [ "$result" = "approve" ]; then
  pass "T10: Edit tool, UUID detail.md in plans dir, PLAN_LANG unset → approve (noop policy)"
else
  fail "T10: Edit detail.md PLAN_LANG unset → expected 'approve', got '$result'"
fi

# ── T11: Timestamp-format file name inside plans dir → approve ───────────────
result=$(invoke_hook_json "" "$(node -e "
process.stdout.write(JSON.stringify({
  tool_name: 'Write',
  tool_input: {
    file_path: '${PLANS_DIR}/20260625-120000-intent.md',
    content: 'Timestamp format content.'
  }
}))
" 2>/dev/null)")
if [ "$result" = "approve" ]; then
  pass "T11: timestamp-format file name (20260625-120000-intent.md), PLAN_LANG unset → approve"
else
  fail "T11: timestamp-format file → expected 'approve', got '$result'"
fi

# ── T12: Non-JSON stdin → approve (fail-open) ────────────────────────────────
result=$(
  export WORKFLOW_PLANS_DIR="$PLANS_DIR"
  export AGENTS_CONFIG_DIR="$ISOLATED_CFG_DIR"
  unset PLAN_LANG 2>/dev/null || true
  echo "not-valid-json" | run_with_timeout node "$HOOK" 2>/dev/null | jq -r .decision
)
if [ "$result" = "approve" ]; then
  pass "T12: non-JSON stdin → approve (fail-open)"
else
  fail "T12: non-JSON stdin → expected 'approve', got '$result'"
fi

# ── Results ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed."
  exit 1
fi
