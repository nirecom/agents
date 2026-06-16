#!/usr/bin/env bash
# Tests: hooks/lib/sentinel-patterns.js, hooks/confirm-checkpoint.js
# Tags: confirm-plan, sentinel, ssot, pr-created, layer2
# SSOT verification for the CONFIRM_PR_CREATED sentinel added by #842
# fix-confirm-stall: the regex must live in sentinel-patterns.js and be
# imported by confirm-checkpoint.js (no inline literal).
#
# L3 gap (what this test does NOT catch):
# - confirm-checkpoint.js firing in a real Claude Code PreToolUse session
#   (hook registration wiring — only verifiable via live claude -p run)
# - The PR URL dialog actually opening in VS Code when a real sentinel is echoed
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
AGENTS_DIR_FWD="${AGENTS_DIR//\\//}"
SENTINEL_PATTERNS="$AGENTS_DIR/hooks/lib/sentinel-patterns.js"
SENTINEL_PATTERNS_FWD="$AGENTS_DIR_FWD/hooks/lib/sentinel-patterns.js"
CONFIRM_CHECKPOINT="$AGENTS_DIR/hooks/confirm-checkpoint.js"
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

if [ ! -f "$SENTINEL_PATTERNS" ]; then
  echo "SKIP: sentinel-patterns.js not found"
  exit 0
fi

# ── SSOT-1: CONFIRM_PR_CREATED_RE_DQ is exported (not undefined) ───────────
echo "=== SSOT-1: CONFIRM_PR_CREATED_RE_DQ exported ==="
SSOT1_OUT="$(run_with_timeout node -e "
  try {
    const m = require('$SENTINEL_PATTERNS_FWD');
    process.stdout.write(typeof m.CONFIRM_PR_CREATED_RE_DQ);
  } catch (e) { process.stdout.write('error:' + e.message); }
" 2>/dev/null)"
if [ "$SSOT1_OUT" = "object" ]; then
  pass "CONFIRM_PR_CREATED_RE_DQ is exported (typeof object — RegExp)"
else
  fail "CONFIRM_PR_CREATED_RE_DQ export missing or wrong type: '$SSOT1_OUT'"
fi

# ── SSOT-2: CONFIRM_PR_CREATED_RE_DQ matches valid command ─────────────────
echo "=== SSOT-2: CONFIRM_PR_CREATED_RE_DQ matches valid sentinel ==="
SSOT2_OUT="$(run_with_timeout node -e "
  try {
    const m = require('$SENTINEL_PATTERNS_FWD');
    const cmd = 'echo \"<<WORKFLOW_CONFIRM_PR_CREATED: https://github.com/nirecom/agents/pull/999>>\"';
    process.stdout.write(String(m.CONFIRM_PR_CREATED_RE_DQ.test(cmd)));
  } catch (e) { process.stdout.write('error:' + e.message); }
" 2>/dev/null)"
if [ "$SSOT2_OUT" = "true" ]; then
  pass "CONFIRM_PR_CREATED_RE_DQ matches valid PR-URL command"
else
  fail "CONFIRM_PR_CREATED_RE_DQ failed to match valid command: '$SSOT2_OUT'"
fi

# ── SSOT-3: CONFIRM_PR_CREATED_RE_DQ captures the URL ──────────────────────
echo "=== SSOT-3: CONFIRM_PR_CREATED_RE_DQ captures the PR URL ==="
SSOT3_OUT="$(run_with_timeout node -e "
  try {
    const m = require('$SENTINEL_PATTERNS_FWD');
    const cmd = 'echo \"<<WORKFLOW_CONFIRM_PR_CREATED: https://github.com/nirecom/agents/pull/999>>\"';
    const match = cmd.match(m.CONFIRM_PR_CREATED_RE_DQ);
    process.stdout.write(match && match[1] ? match[1] : 'no-capture');
  } catch (e) { process.stdout.write('error:' + e.message); }
" 2>/dev/null)"
if [ "$SSOT3_OUT" = "https://github.com/nirecom/agents/pull/999" ]; then
  pass "CONFIRM_PR_CREATED_RE_DQ captures the PR URL in group 1"
else
  fail "CONFIRM_PR_CREATED_RE_DQ URL capture wrong: '$SSOT3_OUT'"
fi

# ── SSOT-4: CONFIRM_PR_CREATED_RE_DQ rejects non-URL reason ────────────────
echo "=== SSOT-4: CONFIRM_PR_CREATED_RE_DQ rejects non-URL ==="
SSOT4_OUT="$(run_with_timeout node -e "
  try {
    const m = require('$SENTINEL_PATTERNS_FWD');
    const cmd = 'echo \"<<WORKFLOW_CONFIRM_PR_CREATED: not-a-url>>\"';
    process.stdout.write(String(m.CONFIRM_PR_CREATED_RE_DQ.test(cmd)));
  } catch (e) { process.stdout.write('error:' + e.message); }
" 2>/dev/null)"
if [ "$SSOT4_OUT" = "false" ]; then
  pass "CONFIRM_PR_CREATED_RE_DQ rejects malformed (non-URL) sentinel"
else
  fail "CONFIRM_PR_CREATED_RE_DQ accepted malformed sentinel: '$SSOT4_OUT'"
fi

# ── SSOT-5: CONFIRM_PR_CREATED_LOOKSLIKE_RE matches loose form ─────────────
echo "=== SSOT-5: CONFIRM_PR_CREATED_LOOKSLIKE_RE matches loose form ==="
SSOT5_OUT="$(run_with_timeout node -e "
  try {
    const m = require('$SENTINEL_PATTERNS_FWD');
    if (!m.CONFIRM_PR_CREATED_LOOKSLIKE_RE) { process.stdout.write('undefined'); }
    else {
      const cmd = 'echo \"<<WORKFLOW_CONFIRM_PR_CREATED: anything-here>>\"';
      process.stdout.write(String(m.CONFIRM_PR_CREATED_LOOKSLIKE_RE.test(cmd)));
    }
  } catch (e) { process.stdout.write('error:' + e.message); }
" 2>/dev/null)"
if [ "$SSOT5_OUT" = "true" ]; then
  pass "CONFIRM_PR_CREATED_LOOKSLIKE_RE matches loose form"
else
  fail "CONFIRM_PR_CREATED_LOOKSLIKE_RE missing or fails to match loose form: '$SSOT5_OUT'"
fi

# ── SSOT-5b: CONFIRM_PR_CREATED_BODY_RE exported (unanchored, for substring match) ─
echo "=== SSOT-5b: CONFIRM_PR_CREATED_BODY_RE exported ==="
SSOT5B_OUT="$(run_with_timeout node -e "
  try {
    const m = require('$SENTINEL_PATTERNS_FWD');
    if (!m.CONFIRM_PR_CREATED_BODY_RE) { process.stdout.write('undefined'); }
    else {
      const cmd = 'echo \"<<WORKFLOW_CONFIRM_PR_CREATED: https://github.com/nirecom/agents/pull/999>>\"';
      const match = cmd.match(m.CONFIRM_PR_CREATED_BODY_RE);
      process.stdout.write(match && match[1] ? match[1] : 'no-capture');
    }
  } catch (e) { process.stdout.write('error:' + e.message); }
" 2>/dev/null)"
if [ "$SSOT5B_OUT" = "https://github.com/nirecom/agents/pull/999" ]; then
  pass "CONFIRM_PR_CREATED_BODY_RE exported and captures PR URL via substring match"
else
  fail "CONFIRM_PR_CREATED_BODY_RE missing or wrong capture: '$SSOT5B_OUT'"
fi

# ── SSOT-6: confirm-checkpoint.js imports CONFIRM_PR_CREATED_BODY_RE ────────
echo "=== SSOT-6: confirm-checkpoint.js imports CONFIRM_PR_CREATED_BODY_RE ==="
if [ -f "$CONFIRM_CHECKPOINT" ]; then
  if grep -F "CONFIRM_PR_CREATED_BODY_RE" "$CONFIRM_CHECKPOINT" >/dev/null 2>&1; then
    pass "confirm-checkpoint.js references CONFIRM_PR_CREATED_BODY_RE"
  else
    fail "confirm-checkpoint.js does not import CONFIRM_PR_CREATED_BODY_RE from sentinel-patterns"
  fi
else
  fail "confirm-checkpoint.js not found"
fi

# ── SSOT-7: confirm-checkpoint.js no longer carries the old inline literal ─
echo "=== SSOT-7: confirm-checkpoint.js: old inline literal removed ==="
if [ -f "$CONFIRM_CHECKPOINT" ]; then
  if grep -F "<<WORKFLOW_CONFIRM_PR_CREATED: (https" "$CONFIRM_CHECKPOINT" >/dev/null 2>&1; then
    fail "confirm-checkpoint.js still contains the old inline CONFIRM_PR_CREATED regex literal"
  else
    pass "confirm-checkpoint.js no longer contains old inline literal"
  fi
fi

# ── Results ─────────────────────────────────────────────────────────────────
echo
if [ "$ERRORS" -eq 0 ]; then
  echo "All SSOT checks passed."
  exit 0
else
  echo "$ERRORS SSOT check(s) failed."
  exit 1
fi
