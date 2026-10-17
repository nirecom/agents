#!/usr/bin/env bash
# tests/hooks/feat-2529-intent-glossary-hooks.sh
# Tests: hooks/gate-plan-lang.js, hooks/check-plan-lang.js, hooks/lib/plan-artifact-lang.js, skills/workflow-init/SKILL.md
# Tags: glossary, intent, hook, pretooluse, posttooluse, plans, scope:issue-specific, TL2, regression-2529
# lang-check: ignore -- the japanese-policy fixture carries CJK prose
# #2529: the plan-lang hooks run the intent `## Glossary` structure check beside the language lint.
# TL3 gap: no live Claude Code dispatch; hooks run on synthetic stdin. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.
# TDD RED until lintPlanArtifactStructure and the hook wiring land.
set -u
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"; readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT" 2>/dev/null || true' EXIT
harness_isolate "$TMP_ROOT/iso"
export WORKFLOW_STATE_DIR="$(np "$TMP_ROOT/iso/workflow-state")"
export WORKFLOW_PLANS_DIR="$(np "$TMP_ROOT/iso/plans")"
mkdir -p "$TMP_ROOT/cwd" "$TMP_ROOT/cfg-ja" "$TMP_ROOT/cfg-none" "$TMP_ROOT/cfg-en"
printf 'PLAN_LANG=japanese\n' > "$TMP_ROOT/cfg-ja/.env"
: > "$TMP_ROOT/cfg-none/.env"
printf 'PLAN_LANG=english\n' > "$TMP_ROOT/cfg-en/.env"
CFG_JA="$(np "$TMP_ROOT/cfg-ja")"; CFG_NONE="$(np "$TMP_ROOT/cfg-none")"; CFG_EN="$(np "$TMP_ROOT/cfg-en")"

GATE="$SCRIPT_CHECKOUT_ROOT/hooks/gate-plan-lang.js"
CHECK="$SCRIPT_CHECKOUT_ROOT/hooks/check-plan-lang.js"
SKILL_MD="$SCRIPT_CHECKOUT_ROOT/skills/workflow-init/SKILL.md"
INTENT="$WORKFLOW_PLANS_DIR/20260625-120000-intent.md"
OUTLINE="$WORKFLOW_PLANS_DIR/20260625-120000-outline.md"
DETAIL="$WORKFLOW_PLANS_DIR/20260625-120000-detail.md"

EN_BODY='This paragraph is written entirely in English prose for the gate.'
JA_BODY='この段落は日本語で書かれています。'
NO_GLOSSARY=$'## Issues\n\n- #1: sample\n\n## Background / Motivation\n\n'
WITH_GLOSSARY=$'## Issues\n\n- #1: sample\n\n## Glossary\n\n## Background / Motivation\n\n'

# Payload / reason helpers live in a heredoc file (no multi-line quoted JS before markers).
cat > "$TMP_ROOT/helpers.js" <<'JS'
// node helpers.js payload <tool> <file> <content|-> | node helpers.js reason <stdout>
const [mode, a, b, c] = process.argv.slice(2);
if (mode === 'payload') {
  const ti = { file_path: b };
  if (a === 'Write') ti.content = c;
  else { ti.old_string = 'x'; ti.new_string = c; }
  process.stdout.write(JSON.stringify({ tool_name: a, tool_input: ti, tool_response: {} }));
} else if (mode === 'reason') {
  try {
    const o = JSON.parse(a.trim());
    process.stdout.write(o.decision === 'block' && typeof o.reason === 'string' ? o.reason : '');
  } catch (e) { process.stdout.write(''); }
}
JS
HELPERS_JS="$(np "$TMP_ROOT/helpers.js")"
payload() { run_with_timeout 10 node "$HELPERS_JS" payload "$@"; }

# run_hook <hook> <payload> <cfg> — neutral cwd, policy keys and session ids removed; sets OUT, REASON.
run_hook() {
  local hook="$1" pl="$2" cfg="$3"
  OUT="$(
    cd "$TMP_ROOT/cwd" || exit 97
    unset PLAN_LANG DOCS_LANG_PUBLIC DOCS_LANG_PRIVATE CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR
    export AGENTS_MAIN_ROOT="$cfg"
    printf '%s' "$pl" | run_with_timeout 20 node "$hook" 2>/dev/null
  )"
  REASON="$(run_with_timeout 10 node "$HELPERS_JS" reason "$OUT")"
}
has() { [ -n "$REASON" ] && [ "${REASON#*"$1"}" != "$REASON" ]; }
expect_block() {
  if has "$2"; then pass "$1"; else fail "$1" "want block naming '$2', got: $OUT"; fi
}
expect_approve() {
  if [ -z "$REASON" ] && printf '%s' "$OUT" | grep -q '"decision":"approve"'; then pass "$1"; else fail "$1" "want approve, got: $OUT"; fi
}

for _src in "$GATE" "$CHECK" "$SCRIPT_CHECKOUT_ROOT/hooks/lib/intent-glossary.js"; do
  [ -f "$_src" ] || echo "NOTE: source missing (tests-first RED): $_src"
done

# ---- PreToolUse gate: Write on the intent stage only
case_begin "gate-intent-write-without-glossary-blocks" "hooks/gate-plan-lang.js"
run_hook "$GATE" "$(payload Write "$INTENT" "$NO_GLOSSARY$EN_BODY")" "$CFG_EN"
expect_block "gate: intent Write lacking ## Glossary → block" "[gate-plan-lang] intent structure"
if [ -n "$REASON" ] && ! has "Rewrite the fragment(s) in"; then
  pass "gate: structure-only block carries no language-rewrite instruction"
else
  fail "gate: structure-only block" "want no 'Rewrite the fragment(s) in', got: $REASON"
fi
case_end

case_begin "gate-intent-write-with-glossary-approves" "hooks/gate-plan-lang.js"
run_hook "$GATE" "$(payload Write "$INTENT" "$WITH_GLOSSARY$EN_BODY")" "$CFG_EN"
if [ "$OUT" = '{"decision":"approve"}' ]; then pass "gate: intent Write with ## Glossary → exact approve"; else fail "gate: with ## Glossary" "got: $OUT"; fi
case_end

case_begin "gate-edit-fragment-skips-structure" "hooks/gate-plan-lang.js"
run_hook "$GATE" "$(payload Edit "$INTENT" "$EN_BODY")" "$CFG_EN"
expect_approve "gate: intent Edit fragment is not structure-checked → approve"
case_end

case_begin "gate-outline-detail-skip-structure" "hooks/gate-plan-lang.js"
run_hook "$GATE" "$(payload Write "$OUTLINE" "$EN_BODY")" "$CFG_EN"
expect_approve "gate: outline Write without ## Glossary → approve"
run_hook "$GATE" "$(payload Write "$DETAIL" "$EN_BODY")" "$CFG_EN"
expect_approve "gate: detail Write without ## Glossary → approve"
case_end

case_begin "gate-structure-runs-without-plan-lang" "hooks/gate-plan-lang.js"
run_hook "$GATE" "$(payload Write "$INTENT" "$NO_GLOSSARY$EN_BODY")" "$CFG_NONE"
expect_block "gate: PLAN_LANG unset still blocks an intent lacking ## Glossary" "intent structure"
case_end

# ---- PostToolUse checker: full text (content, or the on-disk file for Edit)
case_begin "check-edit-reads-on-disk-intent" "hooks/check-plan-lang.js"
printf '%s' "$NO_GLOSSARY$EN_BODY" > "$INTENT"
run_hook "$CHECK" "$(payload Edit "$INTENT" "$EN_BODY")" "$CFG_EN"
expect_block "check: Edit with on-disk intent lacking ## Glossary → block" "[check-plan-lang] intent structure"
printf '%s' "$WITH_GLOSSARY$EN_BODY" > "$INTENT"
run_hook "$CHECK" "$(payload Edit "$INTENT" "$EN_BODY")" "$CFG_EN"
expect_approve "check: Edit with on-disk intent carrying ## Glossary → approve"
rm -f "$INTENT"
case_end

case_begin "check-language-and-structure-one-message" "hooks/check-plan-lang.js"
run_hook "$CHECK" "$(payload Write "$INTENT" "$NO_GLOSSARY$EN_BODY")" "$CFG_JA"
expect_block "check: japanese policy + English body → language violation reported" "PLAN_LANG=japanese"
expect_block "check: same message also reports the structure violation" "intent structure"
case_end

case_begin "check-structure-runs-without-plan-lang" "hooks/check-plan-lang.js"
run_hook "$CHECK" "$(payload Write "$INTENT" "$NO_GLOSSARY$JA_BODY")" "$CFG_NONE"
expect_block "check: PLAN_LANG unset still blocks an intent lacking ## Glossary" "intent structure"
case_end

# ---- Skill prose: workflow-init A1 lists ## Glossary right after ## Issues
case_begin "workflow-init-a1-lists-glossary-after-issues" "skills/workflow-init/SKILL.md"
_a1="$(grep -m1 -E '^- A1\.' "$SKILL_MD" 2>/dev/null)"
_heads="$(printf '%s' "$_a1" | grep -oE '`## [^`]+`' | tr -d '`')"
_after="$(printf '%s\n' "$_heads" | grep -A1 -xF '## Issues' | sed -n '2p')"
if [ -z "$_a1" ]; then
  fail "A1 line" "no '- A1.' line in $SKILL_MD"
elif [ "$_after" = "## Glossary" ]; then
  pass "workflow-init A1: ## Glossary follows ## Issues"
else
  fail "workflow-init A1" "heading after ## Issues is '$_after'"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
