#!/bin/bash
# tests/feature-issue-528-lang-enforce/lint-plan-lang-cases.sh
# Tests: hooks/lib/lint-plan-lang.js
# Tags: worktree, docs, lint, plan, scope:issue-specific
# Sourced by ../feature-issue-528-lang-enforce.sh — helpers come from there.
# lang-check: ignore -- this file intentionally contains CJK test fixtures for CJK-detection tests

# ============================================================================
# Group 9 — lint-plan-lang.js unit tests
# ============================================================================

echo ""
echo "=== Group 9: lint-plan-lang.js unit tests ==="

LINT_PLAN_LIB="$AGENTS_DIR/hooks/lib/lint-plan-lang.js"
if [ "$(src_present "$LINT_PLAN_LIB")" != "ok" ]; then
    echo "SKIP G9: hooks/lib/lint-plan-lang.js not yet implemented (RED phase)"
else
    # T31: blank line → 0 violations
    _t31_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('', 'english');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T31: blank line → 0 violations"; else fail "T31: $_t31_out"; fi

    # T32: heading exempt
    _t32_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('# Heading', 'english');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T32: heading exempt → 0 violations"; else fail "T32: $_t32_out"; fi

    # T33: CJK + english → 1
    _t33_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('日本語テスト', 'english');
      if (v.length !== 1) { process.stderr.write('expected 1, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T33: CJK + english policy → 1 violation"; else fail "T33: $_t33_out"; fi

    # T34: CJK + any → 0
    _t34_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('日本語テスト', 'any');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T34: CJK + any policy → 0 violations"; else fail "T34: $_t34_out"; fi

    # T35: 3 words + japanese → 0 (under threshold)
    _t35_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('Use the API', 'japanese');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T35: 3-word ASCII + japanese → 0 (under threshold)"; else fail "T35: $_t35_out"; fi

    # T36: 5 words + japanese → 1
    _t36_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('Use the new PR API', 'japanese');
      if (v.length !== 1) { process.stderr.write('expected 1, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T36: 5-word ASCII + japanese → 1 violation"; else fail "T36: $_t36_out"; fi

    # T37: fenced CJK stripped
    _t37_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const content = '\`\`\`\n日本語テスト\n\`\`\`';
      const v = lintPlanLang(content, 'english');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T37: CJK inside fenced block → stripped, 0 violations"; else fail "T37: $_t37_out"; fi

    # T38: inline backtick CJK stripped
    _t38_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('use \`日本語\` here', 'english');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T38: CJK inside inline backtick → stripped, 0 violations"; else fail "T38: $_t38_out"; fi

    # T54: issue title prefix stripped → 0 violations (japanese policy, 4-word title)
    _t54_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('- #629: check-plan-lang issue title excluded', 'japanese');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T54: issue ref line - #N: title → 0 violations (japanese)"; else fail "T54: $_t54_out"; fi

    # T55: issue title prefix stripped → 0 violations (japanese policy, 7-word title)
    _t55_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('- #100: auto-resolve Projects v2 config from git remote', 'japanese');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T55: issue ref line - #N: long title → 0 violations (japanese)"; else fail "T55: $_t55_out"; fi

    # T56: issue ref with no title → 0 violations (japanese policy, edge case)
    _t56_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('- #629:', 'japanese');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T56: issue ref line - #N: (empty title) → 0 violations (japanese)"; else fail "T56: $_t56_out"; fi

    # T57: NON_GITHUB sentinel line → 0 violations (#670)
    # The sentinel uses an em-dash (U+2014), NOT ASCII hyphen-minus.
    # Current source has no exemption for this line → test is RED.
    _t57_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const sentinel = '(none — pending issue creation or NON_GITHUB)';
      const v = lintPlanLang(sentinel, 'japanese');
      if (v.length !== 0) { process.stderr.write('expected 0 violations for NON_GITHUB sentinel, got ' + v.length + ': ' + JSON.stringify(v) + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T57: NON_GITHUB sentinel line → 0 violations (japanese, #670)"; else fail "T57: NON_GITHUB sentinel exemption missing: $_t57_out"; fi
fi
