#!/usr/bin/env bash
# tests/feature-943-e2e-post-compact.sh
# Tests: hooks/post-compact.js
# Tags: e2e, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - PostCompact fires only on a real context-compaction event, which cannot be
#   forced from claude -p. This test is registration-only: it asserts the hook is
#   wired in settings.json and is directly invokable, NOT that a live compaction
#   re-injects session state. This is the single planned case with no active
#   runtime evidence — the compaction trigger is unreachable in an automated run.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/post-compact.js"
SETTINGS="$AGENTS_DIR/settings.json"

# R1 only requires node + settings.json; R2-R4 are direct-node invocations with no
# real claude -p. No RUN_E2E gate needed — all cases are deterministic.
command -v node >/dev/null 2>&1 || { echo "SKIP: node not found" >&2; exit 77; }
[ -f "$AGENTS_DIR/settings.json" ] || { echo "SKIP: settings.json not found" >&2; exit 77; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# R1: PostCompact hook is registered in settings.json referencing post-compact.js.
if node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const pc = s.hooks && s.hooks.PostCompact;
  if (!Array.isArray(pc)) process.exit(1);
  const cmds = JSON.stringify(pc);
  process.exit(cmds.includes("post-compact.js") ? 0 : 1);
' "$SETTINGS" 2>/dev/null; then
  pass "R1. settings.json PostCompact registers post-compact.js"
else
  fail "R1. settings.json PostCompact does not reference post-compact.js"
fi

# R2: hook is directly invokable and emits state-injection context for a session.
# On MSYS/Git-Bash, node resolves paths as native Windows. No-op on POSIX.
if command -v cygpath >/dev/null 2>&1; then TMP="$(cygpath -m "$TMP")"; fi
export CLAUDE_WORKFLOW_DIR="$TMP/workflow"
export WORKFLOW_PLANS_DIR="$TMP/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
SID="feature943-pc-00000000-0000-0000-0000-000000000006"

set +e
OUT=$(printf '%s' "{\"hook_event_name\":\"PostCompact\",\"session_id\":\"$SID\"}" | node "$HOOK"); EXIT=$?
set -e
if [ "$EXIT" -eq 0 ] && printf '%s' "$OUT" | grep -q "Current workflow session_id: $SID"; then
  pass "R2. post-compact.js invokable → re-injects session_id context"
else
  fail "R2. expected session_id re-injection; got exit=$EXIT out=$OUT"
fi

# R3: state file present → workflow step statuses appear in output [ACTIVE] ----
# Write a minimal state file with workflow_init=complete, then verify the hook
# surfaces "workflow_init: complete" in the Workflow progress block.
STATE_FILE="$CLAUDE_WORKFLOW_DIR/$SID.json"
node -e '
  const fs = require("fs");
  const f = process.argv[1]; const sid = process.argv[2];
  const state = { session_id: sid, steps: {
    workflow_init:    { status: "complete", updated_at: null },
    clarify_intent:   { status: "pending",  updated_at: null },
    research:         { status: "pending",  updated_at: null },
    outline:          { status: "pending",  updated_at: null },
    detail:           { status: "pending",  updated_at: null },
    write_tests:      { status: "pending",  updated_at: null },
    review_security:  { status: "pending",  updated_at: null },
    docs:             { status: "pending",  updated_at: null },
    user_verification:{ status: "pending",  updated_at: null },
    cleanup:          { status: "pending",  updated_at: null },
  }};
  fs.writeFileSync(f, JSON.stringify(state), "utf8");
' "$STATE_FILE" "$SID"
set +e
OUT3=$(printf '%s' "{\"hook_event_name\":\"PostCompact\",\"session_id\":\"$SID\"}" | node "$HOOK"); EXIT3=$?
set -e
rm -f "$STATE_FILE"
if [ "$EXIT3" -eq 0 ] \
  && printf '%s' "$OUT3" | grep -q "workflow_init: complete" \
  && printf '%s' "$OUT3" | grep -q "Workflow progress:"; then
  pass "R3. state file present → workflow step statuses surfaced in output"
else
  fail "R3. expected 'workflow_init: complete' in output; got exit=$EXIT3 out=$OUT3"
fi

# R4: CONV_LANG injection → directive appended to additionalContext ---------------
set +e
OUT4=$(printf '%s' "{\"hook_event_name\":\"PostCompact\",\"session_id\":\"$SID\"}" \
  | CONV_LANG=japanese node "$HOOK"); EXIT4=$?
set -e
if [ "$EXIT4" -eq 0 ] && printf '%s' "$OUT4" | grep -q "Respond to the user in japanese"; then
  pass "R4. CONV_LANG=japanese → conv-lang directive appended to additionalContext"
else
  fail "R4. expected conv-lang directive; got exit=$EXIT4 out=$OUT4"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
