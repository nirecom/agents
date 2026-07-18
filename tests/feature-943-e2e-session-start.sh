#!/usr/bin/env bash
# tests/feature-943-e2e-session-start.sh
# Tests: hooks/session-start.js
# Tags: e2e, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - E2/E3 are direct-stdin; the real SessionStart event and process env isolation
#   are not exercised (CONV_LANG is injected via process.env, not parsed from .env).
# - State inheritance (#772 fix: prior session same cwd+branch → steps carried
#   forward, cleanup forced to "skipped") — requires pre-seeded prior-session state.
# - Settings-drift check (settings.json hash comparison).
# - Zombie cleanup (7-day threshold for stale sessions).
# - CLAUDE_SESSION_ID written to CLAUDE_ENV_FILE.
# - writeSetIssue / VS Code session-title path.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/session-start.js"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found" >&2; exit 77; }
[ -f "$HOOK" ] || { echo "SKIP: hook not found: $HOOK" >&2; exit 77; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# On MSYS/Git-Bash, node/claude resolve paths as native Windows. No-op on POSIX.
if command -v cygpath >/dev/null 2>&1; then TMP="$(cygpath -m "$TMP")"; fi

export CLAUDE_WORKFLOW_DIR="$TMP/workflow"
export WORKFLOW_PLANS_DIR="$TMP/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"

# --- E2: direct-stdin → additionalContext contains workflow status [ACTIVE] -----
# Primary output path: hook creates state file and emits additionalContext JSON
# with a "# Workflow status" block listing all steps as pending.
SID_DIRECT="feature943-ss-00000000-0000-0000-0000-000000000010"
set +e
OUT2="$(printf '%s' "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$SID_DIRECT\"}" \
  | AGENTS_DIR="$AGENTS_DIR" node "$HOOK")"; EXIT2=$?
set -e
if [ "$EXIT2" -eq 0 ] \
  && printf '%s' "$OUT2" | grep -q "Workflow status" \
  && printf '%s' "$OUT2" | grep -q "workflow_init: pending"; then
  pass "E2. direct-stdin → additionalContext contains workflow status with pending steps"
else
  fail "E2. expected additionalContext with 'Workflow status' + 'workflow_init: pending'; got exit=$EXIT2 out=$OUT2"
fi

# --- E3: CONV_LANG=japanese → conv-lang directive in additionalContext [ACTIVE] -
# getConvLangInjection() appends to the same lines array as buildWorkflowStatus.
# Verifies that the conv-lang path in session-start.js is wired correctly.
SID_LANG="feature943-ss-00000000-0000-0000-0000-000000000011"
set +e
OUT3="$(printf '%s' "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$SID_LANG\"}" \
  | AGENTS_DIR="$AGENTS_DIR" CONV_LANG=japanese node "$HOOK")"; EXIT3=$?
set -e
if [ "$EXIT3" -eq 0 ] && printf '%s' "$OUT3" | grep -q "Respond to the user in japanese"; then
  pass "E3. CONV_LANG=japanese → conv-lang directive injected in additionalContext"
else
  fail "E3. expected CONV_LANG directive in additionalContext; got exit=$EXIT3 out=$OUT3"
fi

# --- E1: full real claude -p session (RUN_E2E required) -------------------------
if ! [ -x "$AGENTS_DIR/bin/get-config-var" ] || \
   "$AGENTS_DIR/bin/get-config-var" --is-off RUN_E2E off || \
   ! command -v claude >/dev/null 2>&1; then
  echo "Results: PASS=$PASS FAIL=$FAIL (E1 skipped: RUN_E2E off or claude not found)"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

SID="feature943-ss-00000000-0000-0000-0000-000000000004"

REPO="$TMP/repo"
mkdir -p "$REPO/.claude"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"

# Minimal settings.json: only the SessionStart hook under test.
cat > "$REPO/.claude/settings.json" << SETTINGS_EOF
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "node \"$AGENTS_DIR/hooks/session-start.js\"", "timeout": 10 }
        ]
      }
    ]
  }
}
SETTINGS_EOF

STATE_FILE="$CLAUDE_WORKFLOW_DIR/$SID.json"

unset CLAUDECODE
set +e
OUTPUT=$(
  cd "$REPO" &&
  CLAUDE_WORKFLOW_DIR="$CLAUDE_WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR" AGENTS_DIR="$AGENTS_DIR" \
  "$AGENTS_DIR/bin/run-with-timeout.sh" 180 claude -p \
    'Reply with the single word: ok' \
    --session-id "$SID" \
    --setting-sources project \
    --dangerously-skip-permissions \
    --output-format text \
  2>&1
)
EXIT=$?
set -e

# E1: active evidence — session-start created the initial state file for SID.
if [ -f "$STATE_FILE" ]; then
  pass "E1. claude -p SessionStart hook created state file $SID.json"
else
  fail "E1. session-start did not create state file $STATE_FILE. claude exit=$EXIT out=$OUTPUT"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
