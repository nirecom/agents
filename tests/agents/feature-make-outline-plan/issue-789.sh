# Tests: hooks/stop-confirm-plan-guard.js, skills/make-outline-plan/SKILL.md
# Tags: outline, planning, sentinel, workflow, scope:common
# Issue #789 MOP-7/MOP-8 confirmation: Step 8 bypass on "Pass all approaches" selection.
# Sourced by tests/agents/feature-make-outline-plan.sh.

# ---------------------------------------------------------------------------
# Issue #789: Step 8 bypass on "Pass all approaches" selection
# ---------------------------------------------------------------------------
case_begin "Issue 789 MOP-7/MOP-8 confirmation" "hooks/stop-confirm-plan-guard.js"

AGENTS_ROOT_789="$(cd "$(dirname "$0")/../.." && (pwd -W 2>/dev/null || pwd))"
SKILL_789="$AGENTS_ROOT_789/skills/make-outline-plan/SKILL.md"

# 789-1: "Pass all approaches" bypass option absent from SKILL.md (#1522)
assert_absent "$SKILL_789" 'Pass all approaches' \
    "789-1: 'Pass all approaches' bypass option abolished from SKILL.md (#1522)"

# 789-2: MOP-8 references confirm-plan CPA-1+CPA-2 (always-execute contract)
assert_contains "$SKILL_789" 'CPA-1.{0,5}CPA-2' \
    "789-2: SKILL.md MOP-8 references confirm-plan CPA-1+CPA-2 (always-execute contract)"

# 789-3: WORKFLOW_CONFIRM_OUTLINE sentinel retained in SKILL.md (ON path)
assert_contains "$SKILL_789" 'WORKFLOW_CONFIRM_OUTLINE' \
    "789-3: WORKFLOW_CONFIRM_OUTLINE sentinel retained in SKILL.md (ON path)"

# 789-4: CHOSEN_APPROACH variable introduced in SKILL.md Step 7
assert_contains "$SKILL_789" 'CHOSEN_APPROACH' \
    "789-4: CHOSEN_APPROACH variable introduced in SKILL.md Step 7"

# 789-5 + 789-6: Executable Layer 2 guard tests
HOOK_789="$AGENTS_ROOT_789/hooks/stop-confirm-plan-guard.js"

if [[ ! -f "$HOOK_789" ]]; then
    echo "SKIP (789-5): hook not present — skipping Layer 2 guard tests"
elif ! grep -qF "Layer 2" "$HOOK_789" 2>/dev/null; then
    echo "SKIP (789-5): Layer 2 not implemented in hook — skipping"
else
    _789_TMPDIR="$(node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))" 2>/dev/null)/test789-$$"
    _789_CFG="$_789_TMPDIR/cfg"
    _789_PLANS="$_789_TMPDIR/plans"
    # 789-5: isolated session + workflow dir
    _789_SID="test789sid$$"
    _789_WORKFLOW="$_789_TMPDIR/wf5"
    _789_TP="$_789_TMPDIR/t5.jsonl"
    # 789-6: separate session + workflow dir (so 789-5 cleanup doesn't affect 789-6)
    _789b_SID="test789bsid$$"
    _789b_WORKFLOW="$_789_TMPDIR/wf6"
    _789b_TP="$_789_TMPDIR/t6.jsonl"

    mkdir -p "$_789_CFG" "$_789_PLANS" "$_789_WORKFLOW" "$_789b_WORKFLOW"

    # --- 789-5: no-CONFIRM-sentinel bypass turn → Layer 2 must NOT block ---
    # Write turn marker so Layer 2 is actually reached (markers.length === 0 early-exit bypassed)
    printf '%s' '{"created_at":"2026-01-01T00:00:00Z"}' \
      > "$_789_WORKFLOW/$_789_SID.confirm-plan-turn-abcd1234.json"

    # Transcript: prose-summary Bash echo + Skill(make-detail-plan) — no CONFIRM sentinel
    node -e "
      const fs = require('fs');
      const content = [
        { type: 'tool_use', name: 'Bash',
          input: { command: 'echo \"prose summary: all approaches passed to detail planner\"' } },
        { type: 'tool_use', name: 'Skill', input: { skill: 'make-detail-plan' } }
      ];
      const lines = [
        JSON.stringify({ type: 'user', message: { role: 'user', content: 'go' } }),
        JSON.stringify({ type: 'assistant', message: { role: 'assistant', content } })
      ];
      fs.writeFileSync(process.argv[1], lines.join('\n') + '\n');
    " "$_789_TP"

    _789_RC=0
    _789_OUT=$(printf '%s' "{\"session_id\":\"$_789_SID\",\"transcript_path\":\"$_789_TP\"}" | \
      AGENTS_CONFIG_DIR="$_789_CFG" WORKFLOW_PLANS_DIR="$_789_PLANS" WORKFLOW_STATE_DIR="$_789_WORKFLOW" \
      node "$HOOK_789" 2>&1) || _789_RC=$?

    if [ "$_789_RC" -ne 0 ]; then
        fail "789-5" "no-sentinel bypass turn triggered Layer 2 block (exit $_789_RC, out: $_789_OUT)"
    elif echo "$_789_OUT" | grep -qF '"decision"'; then
        fail "789-5" "output contains '\"decision\"' unexpectedly: $_789_OUT"
    else
        pass "789-5: no-sentinel bypass turn exits 0, no decision:block (Layer 2 inert)"
    fi

    # --- 789-6: CONFIRM_OUTLINE sentinel present but no stage-valid follow-up → guard blocks ---
    # Regression: verify guard is still functional (no hook code was changed by this PR)
    printf '%s' '{"created_at":"2026-01-01T00:00:00Z"}' \
      > "$_789b_WORKFLOW/$_789b_SID.confirm-plan-turn-efgh5678.json"

    # Transcript: CONFIRM_OUTLINE Bash echo with no Skill(make-detail-plan) after it
    node -e "
      const fs = require('fs');
      const content = [
        { type: 'tool_use', name: 'Bash',
          input: { command: 'echo \"<<WORKFLOW_CONFIRM_OUTLINE: approach selected>>\"' } }
      ];
      const lines = [
        JSON.stringify({ type: 'user', message: { role: 'user', content: 'go' } }),
        JSON.stringify({ type: 'assistant', message: { role: 'assistant', content } })
      ];
      fs.writeFileSync(process.argv[1], lines.join('\n') + '\n');
    " "$_789b_TP"

    _789b_RC=0
    _789b_OUT=$(printf '%s' "{\"session_id\":\"$_789b_SID\",\"transcript_path\":\"$_789b_TP\"}" | \
      AGENTS_CONFIG_DIR="$_789_CFG" WORKFLOW_PLANS_DIR="$_789_PLANS" WORKFLOW_STATE_DIR="$_789b_WORKFLOW" \
      node "$HOOK_789" 2>&1) || _789b_RC=$?
    _789b_DEC=$(echo "$_789b_OUT" | node -e \
      "let d;try{d=JSON.parse(require('fs').readFileSync(0,'utf8'));}catch(e){process.exit(1);}process.stdout.write(d.decision||'')" \
      2>/dev/null || true)

    if [ "$_789b_RC" -ne 2 ]; then
        fail "789-6" "expected guard to block (exit 2), got exit $_789b_RC, out: $_789b_OUT"
    elif [ "$_789b_DEC" != "block" ]; then
        fail "789-6" "expected decision:block, got '$_789b_DEC'"
    else
        pass "789-6: CONFIRM_OUTLINE sentinel without follow-up → guard blocks (Layer 2 still functional)"
    fi

    # Cleanup both test dirs
    rm -rf "$_789_TMPDIR" 2>/dev/null || true
fi

case_end
echo ""
