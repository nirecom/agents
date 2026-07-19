# shellcheck shell=bash
# TL3 seam body for stop-final-report-guard.js (Stop).
# Sourced by ../TL3-hook-stop-final-report-guard.sh after helpers.sh.

echo ""
echo "=== TL3: stop-final-report-guard.js Stop real invocation (block case) ==="

SFR_SID="e3933200-0000-0000-0000-000000000003"
SFR_BASE="$(make_tmp_base)"
trap 'rm -rf "$SFR_BASE"' EXIT

SFR_REPO="$SFR_BASE/repo"
SFR_WORKFLOW_DIR="$SFR_BASE/workflow"
SFR_PLANS_DIR="$SFR_BASE/plans"
mkdir -p "$SFR_REPO/.claude" "$SFR_WORKFLOW_DIR" "$SFR_PLANS_DIR"

git -C "$SFR_REPO" init -q
git -C "$SFR_REPO" config user.email "test@example.com"
git -C "$SFR_REPO" config user.name "Test"

HOOK_JS="$(node_path "$AGENTS_DIR/hooks/stop-final-report-guard.js")"

# Minimal settings.json: only the Stop hook; no disableBypassPermissionsMode.
cat > "$SFR_REPO/.claude/settings.json" <<SETTINGS_EOF
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

# Fixture arms the guard: env file present → this Stop turn is a Final Report turn.
write_final_report_env "$SFR_PLANS_DIR" "$SFR_SID"

# Prompt omits the Final Report heading entirely → hook fires decision:block, exit 2.
# stop_hook_active re-entry: hook exits 0 on re-entry (prevents infinite loop).
set +e
SFR_OUTPUT=$(
    cd "$SFR_REPO" &&
    unset CLAUDECODE &&
    CLAUDE_WORKFLOW_DIR="$SFR_WORKFLOW_DIR" \
    WORKFLOW_PLANS_DIR="$SFR_PLANS_DIR" \
    run_with_timeout 180 claude -p \
        'Output the exact text: DONE' \
        --session-id "$SFR_SID" \
        --setting-sources project \
        --dangerously-skip-permissions \
        --output-format text \
    2>&1
)
SFR_RC=$?
set -e

# PRIMARY assert: claude exits non-zero because the Stop hook blocked (deterministic).
if [ "$SFR_RC" -ne 0 ]; then
    pass "SFR-E1. stop-final-report-guard.js blocked missing Final Report → claude exit non-zero (rc=$SFR_RC)"
else
    fail "SFR-E1. expected non-zero exit from Stop block, got rc=0. output: $SFR_OUTPUT"
fi

# TL3 gap: the pass-case (all 13 headings emitted → exit 0) is non-deterministic
# because it depends on the model reproducing every heading verbatim; only the
# deterministic block case is exercised here.
