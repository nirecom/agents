# Tests: agents/outline-planner.md, agents/outline-reviewer.md, skills/make-outline-plan/SKILL.md
# Tags: outline, planning, skill, scope:common
# Normal cases (SKILL_MD, PLANNER_MD, REVIEWER_MD), Error cases, Edge cases.
# Sourced by tests/agents/feature-make-outline-plan.sh.

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

# N14 (#2100): REVIEWER_MD frontmatter keeps a fallback model: equal to the reviewer
# role default in ROLE_TABLE (hooks/lib/role-model.js). First ---...--- pair only.
# Tests LOCAL_REVIEWER_MD (worktree copy).
_n14_js="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/role-model.js")"
_n14_want=$(ROLE_MODEL_JS="$_n14_js" node - 2>/dev/null <<'JS'
const t = require(process.env.ROLE_MODEL_JS).ROLE_TABLE.reviewer;
process.stdout.write(t && typeof t.default === "string" ? t.default : "");
JS
)
if [ -z "$_n14_want" ]; then
    fail "N14" "ROLE_TABLE reviewer default unreadable from hooks/lib/role-model.js"
elif [ ! -f "$LOCAL_REVIEWER_MD" ]; then
    fail "N14" "LOCAL_REVIEWER_MD not found ($LOCAL_REVIEWER_MD)"
else
    # Extract only the first frontmatter block (first ---...--- pair), CR-stripped
    _fm="$(tr -d '\r' < "$LOCAL_REVIEWER_MD" | awk '/^---/{if(++n==1){f=1;next} if(n==2){exit}} f' 2>/dev/null || true)"
    _n14_got="$(printf '%s\n' "$_fm" | sed -n 's/^model:[[:space:]]*//p' | head -1 | sed 's/[[:space:]]*$//')"
    if [ -z "$_fm" ]; then
        fail "N14" "LOCAL_REVIEWER_MD has no frontmatter block"
    elif [ "$_n14_got" = "$_n14_want" ]; then
        pass "N14: LOCAL_REVIEWER_MD frontmatter model: $_n14_want equals reviewer ROLE_TABLE default"
    else
        fail "N14" "LOCAL_REVIEWER_MD frontmatter model: '$_n14_got' != reviewer ROLE_TABLE default '$_n14_want'"
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
