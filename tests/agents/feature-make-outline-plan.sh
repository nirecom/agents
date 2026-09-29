#!/usr/bin/env bash
# Tests: agents/outline-planner.md, agents/outline-reviewer.md, skills/_shared/codex-review-loop.md, skills/make-outline-plan/SKILL.md, hooks/stop-confirm-plan-guard.js
# Tags: outline, planning, sentinel, workflow, skill, scope:common
# Contract tests for make-outline-plan skill (Stage 2: outline-planner + outline-reviewer)
# L3 gap: live MOP-8 sentinel auto-selection and VS Code prose-summary rendering are
#   verifiable only in a live session; checked at WORKFLOW_USER_VERIFIED preflight
#   via bin/check-verification-gate.sh category: skill-orchestration.
# Exit 0 always — this is a contract test, not a CI gate yet.

if [ -z "$_TIMEOUT_WRAPPED" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

SKILL_MD="$HOME/.claude/skills/make-outline-plan/SKILL.md"
PLANNER_MD="$HOME/.claude/agents/outline-planner.md"
REVIEWER_MD="$HOME/.claude/agents/outline-reviewer.md"

# LOCAL_* point at the worktree copies (rules/test/fixture-isolation.md).
# Assertions about changes in this branch must use LOCAL_* — they fail pre-merge otherwise.
_SELF_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOCAL_SKILL_MD="$_SELF_DIR/skills/make-outline-plan/SKILL.md"
LOCAL_REVIEWER_MD="$_SELF_DIR/agents/outline-reviewer.md"
AGENTS_DIR="$_SELF_DIR"

# shellcheck source=../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

# assert_contains FILE PATTERN DESCRIPTION
# Greps FILE for PATTERN (extended regex). Prints PASS/FAIL.
assert_contains() {
    local file="$1"
    local pattern="$2"
    local desc="$3"

    if [ ! -f "$file" ]; then
        fail "$desc" "file not found: $file"
        return 1
    fi

    if grep -qE "$pattern" "$file"; then
        pass "$desc"
        return 0
    else
        fail "$desc" "pattern not found: $pattern"
        return 1
    fi
}

# assert_absent FILE PATTERN DESCRIPTION
# Asserts FILE does NOT contain PATTERN. Prints PASS/FAIL.
assert_absent() {
    local file="$1"
    local pattern="$2"
    local desc="$3"

    if [ ! -f "$file" ]; then
        fail "$desc" "file not found: $file"
        return 1
    fi

    if grep -qE "$pattern" "$file"; then
        fail "$desc" "pattern unexpectedly found: $pattern"
        return 1
    else
        pass "$desc"
        return 0
    fi
}

echo "=== make-outline-plan contract tests ==="
echo ""

# ---------------------------------------------------------------------------
# Normal cases — SKILL_MD
# ---------------------------------------------------------------------------
case_begin "Normal SKILL_MD" "skills/make-outline-plan/SKILL.md"

# N1: frontmatter name: make-outline-plan
assert_contains "$SKILL_MD" "name:[[:space:]]*make-outline-plan" \
    "N1: frontmatter contains 'name: make-outline-plan'"

# N2: outline-planner referenced
assert_contains "$SKILL_MD" "outline-planner" \
    "N2: outline-planner referenced in SKILL_MD"

# N3: outline-reviewer referenced
assert_contains "$SKILL_MD" "outline-reviewer" \
    "N3: outline-reviewer referenced in SKILL_MD"

# N4: 2-round max mentioned
assert_contains "$SKILL_MD" "revision_rounds|2.*round|round.*2" \
    "N4: 2-round max mentioned in SKILL_MD"

# N5: <session-id>-approach.md output mentioned
assert_contains "$SKILL_MD" "approach\.md" \
    "N5: approach.md output filename mentioned in SKILL_MD"

# N6: reads intent.md as input
assert_contains "$SKILL_MD" "intent\.md" \
    "N6: intent.md referenced as input in SKILL_MD"

# N7: SINGLE_APPROACH_JUSTIFIED mentioned
assert_contains "$SKILL_MD" "SINGLE_APPROACH_JUSTIFIED" \
    "N7: SINGLE_APPROACH_JUSTIFIED mentioned in SKILL_MD"

case_end
echo ""
# ---------------------------------------------------------------------------
# Normal cases — PLANNER_MD
# ---------------------------------------------------------------------------
case_begin "Normal PLANNER_MD" "agents/outline-planner.md"

# N8 (#2100): MOP-2 runs read-complexity-evaluation --stage outline and passes its
# model= to the outline-planner dispatch. Scoped to the MOP-2 step block (`MOP-2.`
# up to the next `MOP-3.`) so a `model:` in the frontmatter or another step cannot
# satisfy it. Tests LOCAL_SKILL_MD (worktree copy). FAILS until MOP-2 is updated.
if [ ! -f "$LOCAL_SKILL_MD" ]; then
    fail "N8" "LOCAL_SKILL_MD not found ($LOCAL_SKILL_MD)"
else
    _mop2="$(awk '/^MOP-2\./{f=1} /^MOP-3\./{f=0} f' "$LOCAL_SKILL_MD" 2>/dev/null || true)"
    if [ -z "$_mop2" ]; then
        fail "N8" "LOCAL_SKILL_MD has no 'MOP-2.' step block"
    else
        if printf '%s\n' "$_mop2" | grep -qF 'read-complexity-evaluation'; then
            pass "N8a: MOP-2 block runs read-complexity-evaluation"
        else
            fail "N8a: MOP-2 block does not run read-complexity-evaluation"
        fi
        if printf '%s\n' "$_mop2" | grep -qF -- '--stage outline'; then
            pass "N8b: MOP-2 block passes --stage outline"
        else
            fail "N8b: MOP-2 block does not pass --stage outline"
        fi
        if printf '%s\n' "$_mop2" | grep -E 'subagent_type: *`?outline-planner' | grep -qE 'model:'; then
            pass "N8c: MOP-2 outline-planner dispatch line carries model:"
        else
            fail "N8c: MOP-2 outline-planner dispatch line (subagent_type: outline-planner) has no model:"
        fi
    fi
    # N8d: the rule line that binds EVERY outline-planner launch site to the MOP-2
    # model (detail.md Step 5). Stable tokens: outline-planner, MOP-2, model, and
    # each launch-site id — MOP-3, MOP-4, MOP-4a, MOP-5, MOP-8 — on one line.
    _n8d="$(grep -F 'outline-planner' "$LOCAL_SKILL_MD" 2>/dev/null | grep -F 'MOP-2' | grep -F 'model' \
        | grep -F 'MOP-3' | grep -F 'MOP-4a' | grep -F 'MOP-5' | grep -F 'MOP-8' | grep -cE 'MOP-4([^a0-9]|$)')"
    if [ "${_n8d:-0}" -ge 1 ]; then
        pass "N8d: rule line says every outline-planner launch site (MOP-3/4/4a/5/8) passes the MOP-2 model"
    else
        fail "N8d: no rule line binding every outline-planner launch site (MOP-3/4/4a/5/8) to the MOP-2 model"
    fi
fi

# N9: 2-3 approaches required or mutually exclusive
assert_contains "$PLANNER_MD" "2.{0,30}3.*approach|mutually.exclusive|相互に排他" \
    "N9: 2-3 approaches required or mutually exclusive stated in PLANNER_MD"

# N10: file paths prohibited
assert_contains "$PLANNER_MD" "file path.*禁止|禁止.*file path|do not.*file path|prohibit.*path|[Ss]trictly forbidden|ファイル.*パス.*禁止|禁止.*ファイル.*パス" \
    "N10: file paths prohibited stated in PLANNER_MD"

# N11: SINGLE_APPROACH_JUSTIFIED defined
assert_contains "$PLANNER_MD" "SINGLE_APPROACH_JUSTIFIED" \
    "N11: SINGLE_APPROACH_JUSTIFIED defined in PLANNER_MD"

# N12: NEEDS_RESEARCH escape hatch
assert_contains "$PLANNER_MD" "NEEDS_RESEARCH" \
    "N12: NEEDS_RESEARCH escape hatch defined in PLANNER_MD"

# N13: tradeoff per approach
assert_contains "$PLANNER_MD" "tradeoff|trade.off|トレードオフ" \
    "N13: tradeoff per approach mentioned in PLANNER_MD"

case_end
echo ""
# ---------------------------------------------------------------------------
# Normal cases — REVIEWER_MD
# ---------------------------------------------------------------------------
case_begin "Normal REVIEWER_MD" "agents/outline-reviewer.md"

# N14: REVIEWER_MD frontmatter must have NO model: line (removed in #2100).
# Checks the first ---...--- pair only to avoid false positives from body text.
# Tests LOCAL_REVIEWER_MD (worktree copy). FAILS until write_code removes model:.
if [ ! -f "$LOCAL_REVIEWER_MD" ]; then
    fail "N14" "LOCAL_REVIEWER_MD not found ($LOCAL_REVIEWER_MD)"
else
    # Extract only the first frontmatter block (first ---...--- pair)
    _fm="$(awk '/^---/{if(++n==1){f=1;next} if(n==2){exit}} f' "$LOCAL_REVIEWER_MD" 2>/dev/null || true)"
    if [ -z "$_fm" ]; then
        fail "N14" "LOCAL_REVIEWER_MD has no frontmatter block"
    elif printf '%s\n' "$_fm" | grep -qE '^model:'; then
        fail "N14" "LOCAL_REVIEWER_MD frontmatter still contains 'model:' (must be removed)"
    else
        pass "N14: LOCAL_REVIEWER_MD frontmatter has no 'model:' line"
    fi
fi

# N15: APPROVED verdict
assert_contains "$REVIEWER_MD" "APPROVED" \
    "N15: APPROVED verdict defined in REVIEWER_MD"

# N16: MISSING_ALTERNATIVE verdict
assert_contains "$REVIEWER_MD" "MISSING_ALTERNATIVE" \
    "N16: MISSING_ALTERNATIVE verdict defined in REVIEWER_MD"

# N17: drill-down / file path comment prohibition
assert_contains "$REVIEWER_MD" "drill.down|file path|ファイル.*パス|step.*level|実装.*詳細" \
    "N17: drill-down or file path comment prohibition in REVIEWER_MD"

case_end
echo ""
# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------
case_begin "Error cases" "agents/outline-reviewer.md"

# E1: NEEDS_REVISION does NOT appear as a verdict option in REVIEWER_MD;
#     MISSING_ALTERNATIVE is the only non-APPROVED path.
assert_absent "$REVIEWER_MD" "NEEDS_REVISION" \
    "E1a: NEEDS_REVISION does NOT appear as a verdict in REVIEWER_MD"

assert_contains "$REVIEWER_MD" "MISSING_ALTERNATIVE" \
    "E1b: MISSING_ALTERNATIVE is present as the replacement non-APPROVED verdict in REVIEWER_MD"

case_end
echo ""
# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------
case_begin "Edge cases" "agents/outline-planner.md"

# Ed1: SINGLE_APPROACH_JUSTIFIED escape path explicitly defined in PLANNER_MD
if [ ! -f "$PLANNER_MD" ]; then
    fail "Ed1" "SINGLE_APPROACH_JUSTIFIED escape path explicitly defined (file not found: $PLANNER_MD)"
elif grep -qF "SINGLE_APPROACH_JUSTIFIED" "$PLANNER_MD"; then
    pass "Ed1: SINGLE_APPROACH_JUSTIFIED full sentinel string appears in PLANNER_MD"
else
    fail "Ed1" "SINGLE_APPROACH_JUSTIFIED full sentinel string must appear in PLANNER_MD"
fi

# Ed2: REVIEWER_MD has exactly 2 verdict options: APPROVED and MISSING_ALTERNATIVE;
#      no LGTM or NEEDS_REVISION third option.
if [ ! -f "$REVIEWER_MD" ]; then
    fail "Ed2" "exactly 2 verdict options in REVIEWER_MD (file not found: $REVIEWER_MD)"
else
    _has_approved=0
    _has_missing_alt=0
    _has_lgtm=0
    _has_needs_revision=0
    grep -qF "APPROVED" "$REVIEWER_MD" && _has_approved=1
    grep -qF "MISSING_ALTERNATIVE" "$REVIEWER_MD" && _has_missing_alt=1
    grep -qE "LGTM" "$REVIEWER_MD" && _has_lgtm=1
    grep -qE "NEEDS_REVISION" "$REVIEWER_MD" && _has_needs_revision=1

    if [ "$_has_approved" -eq 1 ] && [ "$_has_missing_alt" -eq 1 ] && \
       [ "$_has_lgtm" -eq 0 ] && [ "$_has_needs_revision" -eq 0 ]; then
        pass "Ed2: exactly 2 verdict options (APPROVED + MISSING_ALTERNATIVE, no LGTM/NEEDS_REVISION) in REVIEWER_MD"
    else
        fail "Ed2" "exactly 2 verdict options check failed (approved=$_has_approved missing_alt=$_has_missing_alt lgtm=$_has_lgtm needs_revision=$_has_needs_revision)"
    fi
fi

case_end
echo ""
# ---------------------------------------------------------------------------
# Issue #329: Accepted Tradeoffs section + carry-over log symmetry
# ---------------------------------------------------------------------------
case_begin "Issue 329 accepted-tradeoffs" "skills/make-outline-plan/SKILL.md"

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_REPO="$AGENTS_ROOT/skills/make-outline-plan/SKILL.md"
PLANNER_REPO="$AGENTS_ROOT/agents/outline-planner.md"

# #329-1: Accepted Tradeoffs section in SKILL.md
if grep -qF "Accepted Tradeoffs" "$SKILL_REPO" 2>/dev/null; then
    pass "#329-1: 'Accepted Tradeoffs' section present in make-outline-plan/SKILL.md"
else
    fail "#329-1" "'Accepted Tradeoffs' section missing from make-outline-plan/SKILL.md"
fi

# #329-2: Accepted Tradeoffs section in outline-planner.md
if grep -qF "Accepted Tradeoffs" "$PLANNER_REPO" 2>/dev/null; then
    pass "#329-2: 'Accepted Tradeoffs' section present in agents/outline-planner.md"
else
    fail "#329-2" "'Accepted Tradeoffs' section missing from agents/outline-planner.md"
fi

# #329-3: round-log + planner-response trailer mechanism. After the _shared/
# extraction, the SKILL.md references skills/_shared/codex-review-loop.md and
# the shared spec carries the round-log / planner-response wording (SSOT).
SHARED_LOOP="$AGENTS_ROOT/skills/_shared/codex-review-loop.md"
if grep -qF "_shared/codex-review-loop.md" "$SKILL_REPO" 2>/dev/null && \
   grep -qE "round.*log|planner-response" "$SHARED_LOOP" 2>/dev/null; then
    pass "#329-3: SKILL.md references _shared/codex-review-loop.md; shared spec covers round-log / planner-response"
else
    fail "#329-3" "SKILL.md must reference _shared/codex-review-loop.md, and shared spec must cover round-log / planner-response"
fi

case_end
echo ""
# ---------------------------------------------------------------------------
# Issue #462: assemble-mandatory.sh mechanical injection checks
# ---------------------------------------------------------------------------
case_begin "Issue 462 assemble-mandatory" "skills/make-outline-plan/SKILL.md"

AGENTS_ROOT_462="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_462="$AGENTS_ROOT_462/skills/make-outline-plan/SKILL.md"

# M10: assemble-mandatory.sh called in SKILL.md
if grep -q "assemble-mandatory" "$SKILL_462" 2>/dev/null; then
    pass "M10: assemble-mandatory.sh referenced in make-outline-plan/SKILL.md"
else
    fail "M10" "assemble-mandatory.sh NOT referenced in make-outline-plan/SKILL.md"
fi

# M11: SINGLE_APPROACH_JUSTIFIED path also uses assemble-mandatory.sh
# (Both SINGLE_APPROACH_JUSTIFIED and assemble-mandatory must appear in the same file.)
if grep -q "SINGLE_APPROACH_JUSTIFIED" "$SKILL_462" 2>/dev/null && \
   grep -q "assemble-mandatory" "$SKILL_462" 2>/dev/null; then
    pass "M11: SINGLE_APPROACH_JUSTIFIED path and assemble-mandatory.sh both present in SKILL.md"
else
    fail "M11" "SINGLE_APPROACH_JUSTIFIED or assemble-mandatory.sh missing from SKILL.md"
fi

# M12a: planner-side contract present (do not write mandatory sections; authored copies stripped).
# Wording moved away from the direct translation "machine-injected"; the contract — that the
# orchestrator carries these sections and the planner must not write them — must remain.
if grep -qE "[Dd]o NOT (instruct the planner to )?(author|write)|[Dd]o not (instruct the planner to )?(author|write)|planner.authored copies (will be|are) stripped|helper carries them forward" "$SKILL_462" 2>/dev/null; then
    pass "M12a: planner-side 'do not write / authored copies stripped' contract present in make-outline-plan/SKILL.md"
else
    fail "M12a" "SKILL.md missing the planner-side contract (do not write mandatory sections / authored copies are stripped)"
fi

# M12b: no verbatim-copy instruction (machine-injection replaces manual copy)
if ! grep -qE "verbatim.copy|copy.*verbatim" "$SKILL_462" 2>/dev/null; then
    pass "M12b: no 'verbatim copy' instruction in make-outline-plan/SKILL.md (machine-injection replaces it)"
else
    fail "M12b" "'verbatim copy' instruction still present in SKILL.md — should be removed"
fi

case_end
echo ""
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
      AGENTS_CONFIG_DIR="$_789_CFG" WORKFLOW_PLANS_DIR="$_789_PLANS" CLAUDE_WORKFLOW_DIR="$_789_WORKFLOW" \
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
      AGENTS_CONFIG_DIR="$_789_CFG" WORKFLOW_PLANS_DIR="$_789_PLANS" CLAUDE_WORKFLOW_DIR="$_789b_WORKFLOW" \
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
# ---------------------------------------------------------------------------
# Issue #1384: frontrunner-collapse rule
# ---------------------------------------------------------------------------
case_begin "Issue 1384 frontrunner-collapse" "agents/outline-planner.md"

AGENTS_ROOT_1384="$(cd "$(dirname "$0")/../.." && (pwd -W 2>/dev/null || pwd))"
PLANNER_1384="$AGENTS_ROOT_1384/agents/outline-planner.md"
OUTPUT_FORMAT_1384="$AGENTS_ROOT_1384/agents/outline-planner/output-format.md"

# 1384-1: frontrunner-collapse keyword present in outline-planner.md
assert_contains "$PLANNER_1384" "frontrunner-collapse" \
    "1384-1: frontrunner-collapse keyword present in agents/outline-planner.md"

# 1384-2: frontrunner-collapse form present in output-format.md
assert_contains "$OUTPUT_FORMAT_1384" "frontrunner-collapse" \
    "1384-2: frontrunner-collapse form present in agents/outline-planner/output-format.md"

case_end
echo ""
# ---------------------------------------------------------------------------
# Issue #1287: intent-lock collapse rule + straw-alternative prohibition
# ---------------------------------------------------------------------------
case_begin "Issue 1287 intent-lock" "agents/outline-planner.md"

AGENTS_ROOT_1287="$(cd "$(dirname "$0")/../.." && (pwd -W 2>/dev/null || pwd))"
PLANNER_1287="$AGENTS_ROOT_1287/agents/outline-planner.md"

# 1287-1: intent-lock collapse rule keyword present
assert_contains "$PLANNER_1287" "intent.lock" \
    "1287-1: intent-lock collapse rule keyword present in outline-planner.md"

# 1287-2: Accepted Tradeoffs referenced as trigger (unique pattern avoids existing line 113)
assert_contains "$PLANNER_1287" "Accepted Tradeoffs.*has already been decided|already been decided" \
    "1287-2: Accepted Tradeoffs 'has already been decided' language present in outline-planner.md"

# 1287-3: straw-alternative prohibition
assert_contains "$PLANNER_1287" "straw.alternative|straw.mann" \
    "1287-3: straw-alternative prohibition keyword present in outline-planner.md"

# 1287-4: line-101 exception clause
assert_contains "$PLANNER_1287" "Exception.*SINGLE_APPROACH_JUSTIFIED|SINGLE_APPROACH_JUSTIFIED.*Exception" \
    "1287-4: line-101 exception clause referencing SINGLE_APPROACH_JUSTIFIED present in outline-planner.md"

# 1287-5: protocol violation for fabricating alternatives
assert_contains "$PLANNER_1287" "Fabricating alternatives.*protocol violation" \
    "1287-5: protocol violation for fabricating alternatives under intent-lock present in outline-planner.md"

# 1287-6: Procedure pre-check present (verifies Procedure flow, not just Rules)
assert_contains "$PLANNER_1287" "Do not proceed to step 3" \
    "1287-6: Procedure pre-check step present (intent-lock check before step 3)"

case_end
echo ""
echo "=== Summary ==="
echo "PASS: $PASS  FAIL: $FAIL"

exit 0
