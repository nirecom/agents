#!/usr/bin/env bash
# tests/feature-943-e2e-workflow-mark.sh
# Tests: hooks/workflow-mark.js
# Tags: e2e, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Runs a real claude -p session but only for a single MARK_STEP sentinel.
#   The following dispatch paths are covered by L1 unit tests and are NOT
#   exercised here:
#   - NOT_NEEDED handlers (RESEARCH/OUTLINE/DETAIL/WRITE_TESTS_NOT_NEEDED)
#   - WORKFLOW_RESET_FROM (state recovery)
#   - WORKFLOW_USER_VERIFIED handler
#   - WORKFLOW_ENFORCE_WORKTREE_OFF/ON handlers
#   - &&-chained double-sentinel splitting (two sentinels in one Bash command)
#   - merge-class push detection → user_verification reset
#   - subagent backstop (isSubagentCall ignores state writes)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Skip gates (3-stage)
[ -x "$AGENTS_DIR/bin/get-config-var" ] || { echo "SKIP: get-config-var not found" >&2; exit 77; }
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_E2E off && { echo "SKIP: RUN_E2E off" >&2; exit 77; }
command -v claude >/dev/null 2>&1 || { echo "SKIP: claude CLI not found" >&2; exit 77; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# On MSYS/Git-Bash, node/claude resolve paths as native Windows. No-op on POSIX.
if command -v cygpath >/dev/null 2>&1; then TMP="$(cygpath -m "$TMP")"; fi

# Isolate workflow + plans state from the real dirs.
export CLAUDE_WORKFLOW_DIR="$TMP/workflow"
export WORKFLOW_PLANS_DIR="$TMP/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"

SID="feature943-wm-00000000-0000-0000-0000-000000000003"

REPO="$TMP/repo"
mkdir -p "$REPO/.claude"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"

# Minimal settings.json: only the PostToolUse workflow-mark hook.
cat > "$REPO/.claude/settings.json" << SETTINGS_EOF
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "node \"$AGENTS_DIR/hooks/workflow-mark.js\"", "timeout": 10 }
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
    'Run exactly this Bash command and nothing else: echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"' \
    --session-id "$SID" \
    --setting-sources project \
    --dangerously-skip-permissions \
    --output-format text \
  2>&1
)
EXIT=$?
set -e

# Active evidence: workflow-mark wrote the step into the state file.
if [ -f "$STATE_FILE" ]; then
  STATUS=$(node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.stdout.write((s.steps && s.steps.workflow_init && s.steps.workflow_init.status) || "");
  ' "$STATE_FILE" 2>/dev/null)
  if [ "$STATUS" = "complete" ]; then
    pass "E1. claude -p MARK_STEP sentinel → workflow_init=complete in state file"
  else
    fail "E1. state file present but workflow_init.status='$STATUS' (expected complete). exit=$EXIT out=$OUTPUT"
  fi
else
  fail "E1. workflow-mark did not create state file $STATE_FILE. claude exit=$EXIT out=$OUTPUT"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
