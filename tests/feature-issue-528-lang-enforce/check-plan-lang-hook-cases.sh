#!/bin/bash
# tests/feature-issue-528-lang-enforce/check-plan-lang-hook-cases.sh
# Tests: hooks/check-plan-lang.js
# Tags: worktree, docs, hook, plan, scope:issue-specific
# Sourced by ../feature-issue-528-lang-enforce.sh — helpers come from there.
# Also defines CHECK_PLAN_HOOK, which hint-tier-cases.sh reuses, so it must be
# sourced before that file.
# lang-check: ignore -- this file intentionally contains CJK test fixtures for CJK-detection tests

# ============================================================================
# Group 10 — check-plan-lang.js hook integration
# ============================================================================

echo ""
echo "=== Group 10: check-plan-lang.js integration ==="

CHECK_PLAN_HOOK="$AGENTS_DIR/hooks/check-plan-lang.js"
if [ "$(src_present "$CHECK_PLAN_HOOK")" != "ok" ]; then
    echo "SKIP G10: hooks/check-plan-lang.js not yet implemented (RED phase)"
else
    _g10_plans_tmp=$(mktemp -d); TEST_TMPS+=("$_g10_plans_tmp")
    _g10_agents_tmp=$(mktemp -d); TEST_TMPS+=("$_g10_agents_tmp")
    printf 'PLAN_LANG=english\n' > "$_g10_agents_tmp/.env"

    _g10_plans_dir="$(cygpath -m "$_g10_plans_tmp" 2>/dev/null || echo "$_g10_plans_tmp")"
    _g10_agents_dir="$(cygpath -m "$_g10_agents_tmp" 2>/dev/null || echo "$_g10_agents_tmp")"

    run_plan_hook() {
        local json="$1"
        (export WORKFLOW_PLANS_DIR="$_g10_plans_dir"
         export AGENTS_CONFIG_DIR="$_g10_agents_dir"
         echo "$json" | run_with_timeout 10 node "$AGENTS_DIR/hooks/check-plan-lang.js" 2>/dev/null)
    }

    # T39: CJK content in intent.md → block
    _t39_file="$_g10_plans_dir/20260526-223459-intent.md"
    _t39_json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$_t39_file\",\"content\":\"## Planning\n日本語テスト\"},\"tool_response\":{}}"
    _t39_out="$(run_plan_hook "$_t39_json")"
    if echo "$_t39_out" | grep -q '"block"'; then
        pass "T39: CJK in intent.md with PLAN_LANG=english → block"
    else
        fail "T39: expected block, got: $_t39_out"
    fi

    # T40: flat intermediate -detail-draft.md (#866) → approved
    _t40_file="$_g10_plans_dir/20260526-223459-detail-draft.md"
    _t40_json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$_t40_file\",\"content\":\"日本語\"},\"tool_response\":{}}"
    _t40_out="$(run_plan_hook "$_t40_json")"
    if ! echo "$_t40_out" | grep -q '"block"'; then
        pass "T40: flat <sid>-detail-draft.md → approve (intermediate, excluded)"
    else
        fail "T40: expected approve for draft, got: $_t40_out"
    fi

    # T41: file outside PLANS_DIR → approved
    _t41_tmp=$(mktemp); TEST_TMPS+=("$_t41_tmp")
    _t41_file="$(cygpath -m "$_t41_tmp" 2>/dev/null || echo "$_t41_tmp")"
    _t41_json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$_t41_file\",\"content\":\"日本語\"},\"tool_response\":{}}"
    _t41_out="$(run_plan_hook "$_t41_json")"
    if ! echo "$_t41_out" | grep -q '"block"'; then
        pass "T41: file outside PLANS_DIR → approve"
    else
        fail "T41: expected approve for outside-PLANS_DIR, got: $_t41_out"
    fi

    # T42: wrong basename in PLANS_DIR → approved
    _t42_file="$_g10_plans_dir/notes.md"
    _t42_json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$_t42_file\",\"content\":\"日本語\"},\"tool_response\":{}}"
    _t42_out="$(run_plan_hook "$_t42_json")"
    if ! echo "$_t42_out" | grep -q '"block"'; then
        pass "T42: non-artifact basename in PLANS_DIR → approve"
    else
        fail "T42: expected approve for non-artifact name, got: $_t42_out"
    fi

    # T43: editFiles tool → blocked
    _t43_file="$_g10_plans_dir/20260526-223459-outline.md"
    _t43_json="{\"tool_name\":\"editFiles\",\"tool_input\":{\"file_path\":\"$_t43_file\",\"content\":\"日本語テスト\"},\"tool_response\":{}}"
    _t43_out="$(run_plan_hook "$_t43_json")"
    if echo "$_t43_out" | grep -q '"block"'; then
        pass "T43: editFiles tool + CJK content → block"
    else
        fail "T43: expected block for editFiles, got: $_t43_out"
    fi
fi
