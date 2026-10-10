# shellcheck shell=bash
# TL3 seam body for stop-confirm-plan-guard.js (Stop).
# Sourced by ../TL3-hook-stop-confirm-plan-guard.sh after helpers.sh.

echo ""
echo "=== TL3: stop-confirm-plan-guard.js Stop real invocation (marker consumed) ==="

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

HOOK_JS="$(node_path "$SCRIPT_CHECKOUT_ROOT/hooks/stop-confirm-plan-guard.js")"

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

# Pre-create a per-turn marker in WORKFLOW_STATE_DIR. readAndDeleteTurnMarkers()
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
    WORKFLOW_STATE_DIR="$SCP_WORKFLOW_DIR" \
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

# TL3 gap: the block path (path representation in the last assistant turn →
# decision:block) is non-deterministic — it depends on the model echoing a
# plans-dir path. Only marker consumption is exercised deterministically here.

echo ""
echo "=== TL3: Layer 3/plan-url fails open when the plan is unpublished (plan-sync off) ==="
# #2513 Layer 3: a turn that wrote a plan artifact must show its blob URL — but when no URL
# exists (PLAN_SYNC_REMOTE_URL empty, unprovisioned plans dir) the guard must fail open, so a
# plain "DONE" turn ends normally instead of looping on a block it can never satisfy.
SCP_SID3="e4a4a300-0000-0000-0000-000000000043"
SCP_CFG3="$SCP_BASE/cfg3"
mkdir -p "$SCP_CFG3"
printf 'intent body\n' > "$SCP_PLANS_DIR/$SCP_SID3-intent.md"
SCP_MARKER3="$SCP_WORKFLOW_DIR/$SCP_SID3.confirm-plan-turn-l3l3l3l3.json"
printf '{"absPath":"%s","suffix":"intent","ts":1234567890,"created_at":"2026-07-19T00:00:00.000Z"}\n' \
    "$SCP_PLANS_DIR/$SCP_SID3-intent.md" > "$SCP_MARKER3"

set +e
SCP_OUTPUT3=$(
    cd "$SCP_REPO" &&
    unset CLAUDECODE &&
    CLAUDE_WORKFLOW_DIR="$SCP_WORKFLOW_DIR" \
    WORKFLOW_PLANS_DIR="$SCP_PLANS_DIR" \
    AGENTS_CONFIG_DIR="$SCP_CFG3" \
    PLAN_SYNC_REMOTE_URL="" \
    run_with_timeout 180 claude -p \
        'Output the exact text: DONE' \
        --session-id "$SCP_SID3" \
        --setting-sources project \
        --dangerously-skip-permissions \
        --output-format text \
    2>&1
)
SCP_RC3=$?
set -e

if [ "$SCP_RC3" -eq 0 ] && printf '%s' "$SCP_OUTPUT3" | grep -q "DONE" && [ ! -f "$SCP_MARKER3" ]; then
    pass "SCP-E3. unpublished plan + no URL in the turn — Stop not blocked (fail-open), marker consumed"
else
    fail "SCP-E3. unpublished fail-open — rc=$SCP_RC3 marker_left=$([ -f "$SCP_MARKER3" ] && echo yes || echo no) output: $SCP_OUTPUT3"
fi
if printf '%s' "$SCP_OUTPUT3" | grep -qF "Layer 3/plan-url"; then
    fail "SCP-E3b. Layer 3/plan-url block surfaced although no URL exists — output: $SCP_OUTPUT3"
else
    pass "SCP-E3b. no Layer 3/plan-url block surfaced for an unpublished plan"
fi

# TL3 gap (Layer 3, published path): the block path — a published plan whose blob URL the
# model omits — needs a provisioned GitHub-origin plans dir plus a model turn that reliably
# omits the URL, so it is non-deterministic here. tests/hooks/feature-plan-url-stop-guard.sh
# covers it on a synthetic transcript; real Stop dispatch of that block stays a
# hook-registration gap (bin/check-verification-gate.sh).
