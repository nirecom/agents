# shellcheck shell=bash
# L3 seam body for workflow-mark.js (PostToolUse).
# Sourced by ../L3-hook-workflow-mark.sh after helpers.sh.
# Assumes AGENTS_DIR, pass(), fail(), and helpers already loaded.

echo ""
echo "=== L3: workflow-mark.js PostToolUse real invocation ==="

WM_SID="e1e1e1e1-0000-0000-0000-000000000001"
WM_BASE="$(make_tmp_base)"
trap 'rm -rf "$WM_BASE"' EXIT

WM_REPO="$WM_BASE/repo"
WM_WORKFLOW_DIR="$WM_BASE/workflow"
WM_PLANS_DIR="$WM_BASE/plans"
mkdir -p "$WM_REPO/.claude" "$WM_WORKFLOW_DIR" "$WM_PLANS_DIR"

git -C "$WM_REPO" init -q
git -C "$WM_REPO" config user.email "test@example.com"
git -C "$WM_REPO" config user.name "Test"

HOOK_JS="$(node_path "$AGENTS_DIR/hooks/workflow-mark.js")"

# Minimal settings.json: only the PostToolUse (Bash) hook; no disableBypassPermissionsMode.
cat > "$WM_REPO/.claude/settings.json" <<SETTINGS_EOF
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
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

WM_STATE_FILE="$WM_WORKFLOW_DIR/$WM_SID.json"

# WORKFLOW_PLANS_DIR must be absolute (relative paths throw). Both dirs exported before claude -p.
WM_OUTPUT=$(
    cd "$WM_REPO" &&
    unset CLAUDECODE &&
    CLAUDE_WORKFLOW_DIR="$WM_WORKFLOW_DIR" \
    WORKFLOW_PLANS_DIR="$WM_PLANS_DIR" \
    run_with_timeout 180 claude -p \
        'Run exactly this Bash command and nothing else: echo "<<WORKFLOW_MARK_STEP_research_complete>>"' \
        --session-id "$WM_SID" \
        --setting-sources project \
        --dangerously-skip-permissions \
        --output-format text \
    2>&1
)
WM_RC=$?

if [ -f "$WM_STATE_FILE" ]; then
    WM_STATUS=$(node -e "
const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
process.stdout.write((s.steps && s.steps.research && s.steps.research.status) || '');
" -- "$(node_path "$WM_STATE_FILE")" 2>/dev/null)
    if [ "$WM_STATUS" = "complete" ]; then
        pass "WM-E1. workflow-mark.js PostToolUse fired → steps.research.status=complete"
    else
        fail "WM-E1. state file present but research.status=\"$WM_STATUS\" (expected complete). claude rc=$WM_RC output: $WM_OUTPUT"
    fi
else
    fail "WM-E1. state file $WM_STATE_FILE not created. claude rc=$WM_RC output: $WM_OUTPUT"
fi

# L3 gap: only the research→complete mark is exercised. Other sentinels
# (USER_VERIFIED, RESET_FROM, NOT_NEEDED) and the &&-chain multi-sentinel path
# rely on model output cooperation and are covered at L2 in feature-robust-workflow.
