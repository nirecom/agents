# shellcheck shell=bash
# TL3 seam body for session-start.js (SessionStart).
# Sourced by ../TL3-hook-session-start.sh after helpers.sh.

echo ""
echo "=== TL3: session-start.js SessionStart real invocation ==="

SS_SID="e2292100-0000-0000-0000-000000000002"
SS_BASE="$(make_tmp_base)"
trap 'rm -rf "$SS_BASE"' EXIT

SS_REPO="$SS_BASE/repo"
SS_WORKFLOW_DIR="$SS_BASE/workflow"
SS_PLANS_DIR="$SS_BASE/plans"
mkdir -p "$SS_REPO/.claude" "$SS_WORKFLOW_DIR" "$SS_PLANS_DIR"

git -C "$SS_REPO" init -q
git -C "$SS_REPO" config user.email "test@example.com"
git -C "$SS_REPO" config user.name "Test"

HOOK_JS="$(node_path "$AGENTS_DIR/hooks/session-start.js")"

# Minimal settings.json: only the SessionStart hook; no disableBypassPermissionsMode.
cat > "$SS_REPO/.claude/settings.json" <<SETTINGS_EOF
{
  "hooks": {
    "SessionStart": [
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

SS_STATE_FILE="$SS_WORKFLOW_DIR/$SS_SID.json"

# CRITICAL: do NOT pre-create the state file — session-start.js only runs
# createInitialState when no existing state is found for the session.
SS_OUTPUT=$(
    cd "$SS_REPO" &&
    unset CLAUDECODE &&
    CLAUDE_WORKFLOW_DIR="$SS_WORKFLOW_DIR" \
    WORKFLOW_PLANS_DIR="$SS_PLANS_DIR" \
    run_with_timeout 180 claude -p \
        'Output the exact text: SESSION_START_CONFIRMED' \
        --session-id "$SS_SID" \
        --setting-sources project \
        --dangerously-skip-permissions \
        --output-format json \
    2>&1
)
SS_RC=$?

# PRIMARY assert: state file created with all steps pending (initial shape proves createInitialState ran).
if [ -f "$SS_STATE_FILE" ]; then
    SS_ALL_PENDING=$(node -e "
const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const steps=s.steps||{};
const keys=Object.keys(steps);
const allPending = keys.length>0 && keys.every(k => steps[k] && steps[k].status==='pending');
process.stdout.write(allPending ? 'yes' : 'no');
" -- "$(node_path "$SS_STATE_FILE")" 2>/dev/null)
    if [ "$SS_ALL_PENDING" = "yes" ]; then
        pass "SS-E1. session-start.js created initial state with all steps pending"
    else
        fail "SS-E1. state file present but not all steps pending (got \"$SS_ALL_PENDING\"). claude rc=$SS_RC"
    fi
else
    fail "SS-E1. state file $SS_STATE_FILE not created. claude rc=$SS_RC output: $SS_OUTPUT"
fi

# AUXILIARY assert: additionalContext surfaced the session_id line into the live session.
if printf '%s' "$SS_OUTPUT" | grep -qF "Current workflow session_id: $SS_SID"; then
    pass "SS-E2. additionalContext contains 'Current workflow session_id: <sid>'"
else
    fail "SS-E2. additionalContext missing session_id line. claude rc=$SS_RC output: $SS_OUTPUT"
fi

# TL3 gap: CONV_LANG/settings-drift injection branches depend on host env config
# and are not asserted here; covered at L2 in feature-772-session-start-cleanup-inherit.sh.
