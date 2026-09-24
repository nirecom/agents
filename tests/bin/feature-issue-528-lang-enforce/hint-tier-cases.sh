#!/bin/bash
# tests/feature-issue-528-lang-enforce/hint-tier-cases.sh
# Tests: hooks/lib/lang-config.js, hooks/lib/lint-plan-lang.js, hooks/check-plan-lang.js, hooks/lib/lint-worktree-notes-lang.js
# Tags: worktree, docs, hint-tier, plan, scope:issue-specific
# Sourced by ../feature-issue-528-lang-enforce.sh AFTER
# settings-and-detect-cjk-cases.sh and check-plan-lang-hook-cases.sh — it reads
# LANG_CONFIG_LIB and CHECK_PLAN_HOOK from those two.
# lang-check: ignore -- this file intentionally contains CJK test fixtures for CJK-detection tests

# ============================================================================
# Group 12 — arbitrary-language hint tier
# ============================================================================

echo ""
echo "=== Group 12: arbitrary-language hint tier ==="

if [ "$(src_present "$LANG_CONFIG_LIB")" != "ok" ] || [ "$(src_present "$CHECK_PLAN_HOOK")" != "ok" ]; then
    echo "SKIP G12: lang-config / check-plan not yet implemented"
else
    # T47: PLAN_LANG=french preserved verbatim by loadLangConfig
    _t47_tmp=$(mktemp -d); TEST_TMPS+=("$_t47_tmp")
    printf 'PLAN_LANG=french\n' > "$_t47_tmp/.env"
    _t47_dir="$(cygpath -m "$_t47_tmp" 2>/dev/null || echo "$_t47_tmp")"
    _t47_out="$(env -u PLAN_LANG AGENTS_CONFIG_DIR="$_t47_dir" node -e "
      const { loadLangConfig } = require('$_AGENTS_DIR_NODE/hooks/lib/lang-config');
      const v = loadLangConfig('plan');
      if (v !== 'french') { process.stderr.write('got: ' + v + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T47: PLAN_LANG=french preserved verbatim"; else fail "T47: $_t47_out"; fi

    # T48: empty PLAN_LANG → 'any' (fail-open)
    printf 'PLAN_LANG=\n' > "$_t47_tmp/.env"
    _t48_out="$(env -u PLAN_LANG AGENTS_CONFIG_DIR="$_t47_dir" node -e "
      const { loadLangConfig } = require('$_AGENTS_DIR_NODE/hooks/lib/lang-config');
      const v = loadLangConfig('plan');
      if (v !== 'any') { process.stderr.write('got: ' + v + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T48: empty PLAN_LANG → 'any' (fail-open)"; else fail "T48: $_t48_out"; fi

    # T49: lintPlanLang hint-tier vs strict-tier symmetry
    _t49_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const content = 'plain english long sentence here please';
      const hintViolations = lintPlanLang(content, 'french');
      const strictViolations = lintPlanLang(content, 'japanese');
      if (hintViolations.length !== 0) {
        process.stderr.write('hint-tier produced violations: ' + JSON.stringify(hintViolations) + '\n');
        process.exit(1);
      }
      if (strictViolations.length === 0) {
        process.stderr.write('strict-tier should have flagged English-run content\n');
        process.exit(2);
      }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T49: hint-tier (french) → 0 violations; same content under 'japanese' → violation (classifier gates)"; else fail "T49: $_t49_out"; fi

    # T50: check-plan-lang.js PLAN_LANG=french → approve + additionalContext
    _t50_plans_tmp=$(mktemp -d); TEST_TMPS+=("$_t50_plans_tmp")
    _t50_agents_tmp=$(mktemp -d); TEST_TMPS+=("$_t50_agents_tmp")
    printf 'PLAN_LANG=french\n' > "$_t50_agents_tmp/.env"
    _t50_plans_dir="$(cygpath -m "$_t50_plans_tmp" 2>/dev/null || echo "$_t50_plans_tmp")"
    _t50_agents_dir="$(cygpath -m "$_t50_agents_tmp" 2>/dev/null || echo "$_t50_agents_tmp")"
    _t50_file="$_t50_plans_dir/20260526-223459-intent.md"
    _t50_json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$_t50_file\",\"content\":\"日本語\"},\"tool_response\":{}}"
    _t50_out="$(export WORKFLOW_PLANS_DIR="$_t50_plans_dir"; export AGENTS_CONFIG_DIR="$_t50_agents_dir"; echo "$_t50_json" | run_with_timeout 10 node "$CHECK_PLAN_HOOK" 2>/dev/null)"
    _t50_ok=1
    echo "$_t50_out" | grep -q '"approve"' || _t50_ok=0
    echo "$_t50_out" | grep -q 'PLAN_LANG=french' || _t50_ok=0
    echo "$_t50_out" | grep -q 'additionalContext' || _t50_ok=0
    if [ "$_t50_ok" -eq 1 ]; then
        pass "T50: PLAN_LANG=french + CJK content → approve + additionalContext (hint)"
    else
        fail "T50: expected approve+hint, got: $_t50_out"
    fi

    # T52a/T52b: one arbitrary-language config now covers BOTH sections, since
    # History Notes and Changelog Notes read the same key. The old pair pitted
    # per-section values against each other; with a single key the property worth
    # pinning is that neither section is treated as strict under a hint-tier value,
    # so each section is still checked on its own fixture.
    _t52_cfg='{"public":"french","private":"french"}'

    # T52a: CJK History bullet under a hint-tier policy → 0 violations
    _t52a_file="$(write_tmp_file WORKTREE_NOTES.md <<'EOF'
## History Notes
- 日本語のバグ修正

## Changelog Notes
- (none)
EOF
)"
    _t52a_count="$(lint_count "$_t52a_file" "$_t52_cfg" '{"isPrivateRepo":false}')"
    if [ "$_t52a_count" = "0" ]; then
        pass "T52a: public=french + CJK History bullet → 0 violations (hint tier)"
    else
        fail "T52a: expected 0, got: $_t52a_count"
    fi

    # T52b: CJK Changelog bullet under the SAME config → 0 violations (section symmetry)
    _t52b_file="$(write_tmp_file WORKTREE_NOTES.md <<'EOF'
## History Notes
- (none)

## Changelog Notes
- 日本語の変更点
EOF
)"
    _t52b_count="$(lint_count "$_t52b_file" "$_t52_cfg" '{"isPrivateRepo":false}')"
    if [ "$_t52b_count" = "0" ]; then
        pass "T52b: same config + CJK Changelog bullet → 0 violations (both sections share the key)"
    else
        fail "T52b: expected 0, got: $_t52b_count"
    fi

    # T53 REMOVED (#619): legacy DOCS_LANG_HISTORY ignore-test is moot — the
    # fenced-block parser itself is gone, so legacy keys cannot reach the config.
fi
