# shellcheck shell=bash
# L3 seam body for stop-confirm-plan-guard.js (Stop).
# Sourced by ../L3-hook-stop-confirm-plan-guard.sh after helpers.sh.

echo ""
echo "=== L3: stop-confirm-plan-guard.js Stop real invocation (marker consumed) ==="

SCP_SID="e4a4a300-0000-0000-0000-000000000004"
SCP_BASE="$(make_tmp_base)"
trap 'rm -rf "$SCP_BASE"' EXIT

SCP_REPO="$SCP_BASE/repo"
SCP_WORKFLOW_DIR="$SCP_BASE/workflow"
SCP_PLANS_DIR="$SCP_BASE/plans"
mkdir -p "$SCP_REPO/.claude" "$SCP_WORKFLOW_DIR" "$SCP_PLANS_DIR"

git -C "$SCP_REPO" init -q
git -C "$SCP_REPO" config user.email "test@example.com"
git -C "$SCP_REPO" config user.name "Test"

HOOK_JS="$(node_path "$AGENTS_DIR/hooks/stop-confirm-plan-guard.js")"

# Minimal settings.json: only the Stop hook; no disableBypassPermissionsMode.
cat > "$SCP_REPO/.claude/settings.json" <<SETTINGS_EOF
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node \"$HOOK_JS\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF

# Pre-create a per-turn marker in CLAUDE_WORKFLOW_DIR. readAndDeleteTurnMarkers()
# consumes any <sid>.confirm-plan-turn-*.json on Stop.
SCP_MARKER="$SCP_WORKFLOW_DIR/$SCP_SID.confirm-plan-turn-abcd1234.json"
cat > "$SCP_MARKER" <<'MARKER_EOF'
{"absPath":"/tmp/test-plan.md","suffix":"detail","ts":1234567890,"created_at":"2026-07-19T00:00:00.000Z"}
MARKER_EOF

# PRIMARY assert (before): marker exists.
if [ -f "$SCP_MARKER" ]; then
    pass "SCP-E0. turn marker present before Stop"
else
    fail "SCP-E0. turn marker fixture $SCP_MARKER missing before run"
fi

# Prompt emits a plain "DONE" (no path representation → Layer 1 scan is harmless).
set +e
SCP_OUTPUT=$(
    cd "$SCP_REPO" &&
    unset CLAUDECODE &&
    CLAUDE_WORKFLOW_DIR="$SCP_WORKFLOW_DIR" \
    WORKFLOW_PLANS_DIR="$SCP_PLANS_DIR" \
    run_with_timeout 180 claude -p \
        'Output the exact text: DONE' \
        --session-id "$SCP_SID" \
        --setting-sources project \
        --dangerously-skip-permissions \
        --output-format text \
    2>&1
)
SCP_RC=$?
set -e

# PRIMARY assert (after): marker deleted by readAndDeleteTurnMarkers().
if [ ! -f "$SCP_MARKER" ]; then
    pass "SCP-E1. stop-confirm-plan-guard.js consumed (deleted) the turn marker"
else
    fail "SCP-E1. turn marker still present after Stop — hook did not fire. claude rc=$SCP_RC output: $SCP_OUTPUT"
fi

# L3 gap: the block path (path representation in the last assistant turn →
# decision:block) is non-deterministic — it depends on the model echoing a
# plans-dir path. Only marker consumption is exercised deterministically here.
