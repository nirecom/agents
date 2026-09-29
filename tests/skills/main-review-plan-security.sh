#!/usr/bin/env bash
# Tests: skills/review-plan-security/SKILL.md, skills/review-code-security/SKILL.md, agents/plan-security-reviewer.md
# Tags: frontmatter, tests, security, plan, review, scope:common
# Structural tests for skills/review-plan-security/SKILL.md
set -euo pipefail

# TL3 gap (cases 13-18, #2154). TL1 is the correct layer: SKILL.md is a prompt
# document with no executable entry point, so no subprocess can observe routing.
# Verified here: branch → step routing bound to step ROLES (7b), RPS-3's
# disposition vocabulary, and RPS-3 preceding Present in document order.
# NOT verifiable at any available layer: that the orchestrator's natural-language
# execution of RPS-3 actually suppresses a rejected concern from RPS-4's output
# while retaining a sanctioned one — only a real review round shows that.
# Closest-to-action mitigation: on the first post-merge run returning exit 1/2/6,
# compare the presented concerns against RPS-3's recorded dispositions — the
# mitigation review-tests' RT-4 took (b405063f), production-clean since.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENTS_DIR="$ROOT"
PASS=0
FAIL=0
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SKILL="$ROOT/skills/review-plan-security/SKILL.md"
CODE_SKILL="$ROOT/skills/review-code-security/SKILL.md"

echo "=== review-plan-security skill structural tests ==="

case_begin "skill-file-exists" "skills/review-plan-security/SKILL.md"
# --- Normal case 1: SKILL.md exists ---
if [ -f "$SKILL" ]; then
    pass "SKILL.md exists"
else
    fail "SKILL.md does not exist"
fi
case_end

case_begin "frontmatter-required-fields" "skills/review-plan-security/SKILL.md"
# --- Normal case 2: frontmatter has required fields ---
for field in name description model; do
    if [ -f "$SKILL" ] && grep -qE "^${field}:" "$SKILL" 2>/dev/null; then
        pass "frontmatter has '$field'"
    else
        fail "frontmatter missing '$field'"
    fi
done
case_end

case_begin "name-field-correct" "skills/review-plan-security/SKILL.md"
# --- Normal case 3: name field is review-plan-security ---
if [ -f "$SKILL" ] && grep -qE '^name: review-plan-security$' "$SKILL" 2>/dev/null; then
    pass "name is 'review-plan-security'"
else
    fail "name is not 'review-plan-security'"
fi
case_end

case_begin "model-is-sonnet" "skills/review-plan-security/SKILL.md"
# --- Normal case 4: model is sonnet (orchestrator skills use sonnet per #2100) ---
# Requires write_code to change 'model: opus' → 'model: sonnet' — FAILS until then.
if [ -f "$SKILL" ] && grep -qE '^model: sonnet$' "$SKILL" 2>/dev/null; then
    pass "frontmatter model is 'sonnet'"
else
    fail "frontmatter model is not 'sonnet'"
fi
case_end

case_begin "frontmatter-effort-absent" "skills/review-plan-security/SKILL.md"
# --- Normal case 5: effort is ABSENT (effort: line removed in #2100) ---
# Requires write_code to delete 'effort:' from frontmatter — FAILS until then.
if [ -f "$SKILL" ] && grep -qE '^effort:' "$SKILL" 2>/dev/null; then
    fail "frontmatter 'effort:' must be absent (was not yet removed)"
else
    pass "frontmatter 'effort:' is absent"
fi
case_end

case_begin "procedure-section-present" "skills/review-plan-security/SKILL.md"
# --- Normal case 6: has ## Procedure section ---
if [ -f "$SKILL" ] && grep -qE '^## Procedure' "$SKILL" 2>/dev/null; then
    pass "has ## Procedure section"
else
    fail "missing ## Procedure section"
fi
case_end

case_begin "step-labels-present" "skills/review-plan-security/SKILL.md"
# --- Normal case 7: step labels RPS-1 through RPS-5 present ---
for label in RPS-1 RPS-2 RPS-3 RPS-4 RPS-5; do
    if [ -f "$SKILL" ] && grep -qF "$label" "$SKILL" 2>/dev/null; then
        pass "step label '$label' present"
    else
        fail "step label '$label' missing"
    fi
done
case_end

# --- Setup for case 7b: resolve PRESENT_LABEL and SUMMARY_LABEL (used by later cases) ---
PRESENT_LABEL=""
SUMMARY_LABEL=""
present_hit="$(grep -nE '^RPS-[0-9]+\. *Present' "$SKILL" 2>/dev/null | head -1 || true)"
summary_hit="$(grep -nE '^RPS-[0-9]+\. *Summary' "$SKILL" 2>/dev/null | head -1 || true)"
PRESENT_LINE="${present_hit%%:*}"
SUMMARY_LINE="${summary_hit%%:*}"
PRESENT_LABEL="$(printf '%s' "$present_hit" | sed -nE 's/^[0-9]+:(RPS-[0-9]+)\..*/\1/p')"
SUMMARY_LABEL="$(printf '%s' "$summary_hit" | sed -nE 's/^[0-9]+:(RPS-[0-9]+)\..*/\1/p')"

case_begin "present-summary-step-roles" "skills/review-plan-security/SKILL.md"
# --- Normal case 7b (#2154): step ROLES, not just step tokens. ---
if [ -z "$PRESENT_LABEL" ]; then
    fail "7b: no 'RPS-n. Present ...' step found — the presentation role is unassigned"
elif [ "$PRESENT_LABEL" != "RPS-4" ]; then
    fail "7b: the step that PRESENTS concerns is $PRESENT_LABEL, not RPS-4 — line: $present_hit"
elif ! printf '%s' "$present_hit" | grep -qF 'severity'; then
    fail "7b: RPS-4 names itself Present but carries no per-axis severity duty — line: $present_hit"
elif ! printf '%s' "$present_hit" | grep -qF 'mitigation'; then
    fail "7b: RPS-4 names itself Present but proposes no mitigations — line: $present_hit"
else
    pass "7b: RPS-4 is the step that presents concerns with severity and mitigations"
fi

if [ -z "$SUMMARY_LABEL" ]; then
    fail "7b: no 'RPS-n. Summary ...' step found — the final-summary role is unassigned"
elif [ "$SUMMARY_LABEL" != "RPS-5" ]; then
    fail "7b: the final SUMMARY step is $SUMMARY_LABEL, not RPS-5 — line: $summary_hit"
elif ! printf '%s' "$summary_hit" | grep -qF 'no RISK items'; then
    fail "7b: RPS-5 names itself Summary but does not report 'no RISK items' on APPROVED — line: $summary_hit"
else
    pass "7b: RPS-5 is the final Summary step (no RISK items on APPROVED)"
fi
case_end

# Every later case that names a role reads these; an unresolved role must not
# silently degrade a routing assertion into a match against the empty string.
[ -n "$PRESENT_LABEL" ] || PRESENT_LABEL="RPS-4"
[ -n "$SUMMARY_LABEL" ] || SUMMARY_LABEL="RPS-5"

case_begin "references-codex-loop" "skills/review-plan-security/SKILL.md"
# --- Normal case 8: drives Codex via run-codex-review-loop.sh ---
if [ -f "$SKILL" ] && grep -qF 'run-codex-review-loop.sh' "$SKILL" 2>/dev/null; then
    pass "SKILL.md references run-codex-review-loop.sh"
else
    fail "SKILL.md does not reference run-codex-review-loop.sh"
fi
case_end

case_begin "cross-references-review-code-security" "skills/review-code-security/SKILL.md"
# --- Normal case 9: cross-references /review-code-security ---
if [ -f "$SKILL" ] && grep -qF '/review-code-security' "$SKILL" 2>/dev/null; then
    pass "cross-references /review-code-security"
else
    fail "does not cross-reference /review-code-security"
fi
case_end

case_begin "names-plan-security-reviewer" "agents/plan-security-reviewer.md"
# --- Normal case 10: names plan-security-reviewer fallback agent ---
if [ -f "$SKILL" ] && grep -qF 'plan-security-reviewer' "$SKILL" 2>/dev/null; then
    pass "names 'plan-security-reviewer' fallback agent"
else
    fail "does not name 'plan-security-reviewer' fallback agent"
fi
case_end

case_begin "no-absolute-paths" "skills/review-plan-security/SKILL.md"
# --- Edge case 11: no absolute paths (public repo leak check) ---
if [ -f "$SKILL" ] && grep -qiE '(^|[^a-zA-Z])(c:/|/home/|/Users/)' "$SKILL" 2>/dev/null; then
    fail "absolute path found in SKILL.md (public repo leak)"
else
    pass "no absolute paths in SKILL.md"
fi
case_end

case_begin "no-private-repo-references" "skills/review-plan-security/SKILL.md"
# --- Edge case 12: no references to my-private-repo/ ---
if [ -f "$SKILL" ] && grep -qF 'my-private-repo/' "$SKILL" 2>/dev/null; then
    fail "SKILL.md references my-private-repo/ (private repo leak)"
else
    pass "no references to my-private-repo/ in SKILL.md"
fi
case_end

case_begin "exit-1-2-6-routing-to-triage" "skills/review-plan-security/SKILL.md"
# --- Normal case 13 (#2154): every non-APPROVED producer branch routes to the
# Triage step RPS-3, and none of them jumps straight to the Present step RPS-4.
for code in 1 2 6; do
    line="$(grep -E "^- exit ${code} " "$SKILL" 2>/dev/null || true)"
    if [ -z "$line" ]; then
        fail "13: no '- exit $code' branch line found in SKILL.md"
    elif ! printf '%s' "$line" | grep -qF 'RPS-3'; then
        fail "13: exit $code branch does not route to RPS-3 (Triage) — line: $line"
    elif printf '%s' "$line" | grep -qF "$PRESENT_LABEL"; then
        fail "13: exit $code branch reaches the Present step $PRESENT_LABEL directly — line: $line"
    else
        pass "13: exit $code branch routes to RPS-3 (Triage) and not to Present"
    fi
done
case_end

# --- Setup for cases 13b/13d/13c: resolve the exit 3 branch line ---
line3="$(grep -E '^- exit 3 ' "$SKILL" 2>/dev/null || true)"

case_begin "exit-3-needs-revision-triage" "skills/review-plan-security/SKILL.md"
# --- Normal case 13b (#2154): the exit 3 fallback-agent path is symmetric ---
if [ -z "$line3" ]; then
    fail "13b: no '- exit 3' branch line found in SKILL.md"
elif ! printf '%s' "$line3" | grep -qF 'NEEDS_REVISION'; then
    fail "13b: exit 3 branch does not name the fallback NEEDS_REVISION verdict — line: $line3"
elif ! printf '%s' "$line3" | grep -qF 'RPS-3'; then
    fail "13b: exit 3 fallback NEEDS_REVISION does not route to RPS-3 (Triage) — line: $line3"
else
    pass "13b: exit 3 fallback NEEDS_REVISION verdict routes to RPS-3 (Triage)"
fi
case_end

case_begin "exit-3-model-resolve" "skills/review-plan-security/SKILL.md"
# --- Normal case 13d (#2100 Step 5): the exit 3 plan-security-reviewer launch
# passes the model from resolve-role-model --role reviewer. FAILS until then.
if [ -z "$line3" ]; then
    fail "13d: no '- exit 3' branch line found in SKILL.md"
elif ! printf '%s' "$line3" | grep -qF 'plan-security-reviewer'; then
    fail "13d: exit 3 branch does not launch plan-security-reviewer — line: $line3"
elif ! printf '%s' "$line3" | grep -qF 'resolve-role-model'; then
    fail "13d: plan-security-reviewer launch does not resolve its model via resolve-role-model — line: $line3"
elif ! printf '%s' "$line3" | grep -qE -- '--role reviewer([^-a-z]|$)'; then
    fail "13d: plan-security-reviewer launch does not use --role reviewer — line: $line3"
elif ! printf '%s' "$line3" | grep -qE 'model[=:]'; then
    fail "13d: plan-security-reviewer launch does not pass a model: parameter — line: $line3"
else
    pass "13d: plan-security-reviewer launch passes model= from resolve-role-model --role reviewer"
fi
case_end

# Shared by 13c/14/14b: succeeds when TEXT ROUTES into Triage (RPS-3) or Present.
# An explicit skip statement ("skips RPS-3") is not routing, so it is removed before
# the label ban; a negated skip ("does not skip RPS-3") is routing and fails fast.
enters_triage_or_present() {
    local text="$1" labels="RPS-3|$PRESENT_LABEL" stripped
    if printf '%s\n' "$text" | grep -qE "(not|never|n't)[[:space:]]+skip"; then
        return 0
    fi
    stripped="$(printf '%s\n' "$text" | sed -E "s/(^|[^[:alnum:]])[Ss]kip(s|ped|ping)?[[:space:]]+($labels)([^0-9]|\$)/\1\4/g")"
    printf '%s\n' "$stripped" | grep -qE "$labels"
}

case_begin "exit-3-approved-routing" "skills/review-plan-security/SKILL.md"
# --- Normal case 13c (#2154, CPR-ORTH with case 14): the exit 3 fallback path's
# APPROVED verdict must reach RPS-5 (Summary) and touch neither RPS-3 nor RPS-4.
if [ -z "$line3" ]; then
    fail "13c: no '- exit 3' branch line found in SKILL.md"
else
    appr3="$(printf '%s' "$line3" | awk '{ i=index($0,"APPROVED"); if(i==0) exit; s=substr($0,i); j=index(s,"NEEDS_REVISION"); if(j>0) s=substr(s,1,j-1); print s }')"
    if [ -z "$appr3" ]; then
        fail "13c: exit 3 branch states no APPROVED verdict for the fallback agent — line: $line3"
    elif ! printf '%s' "$appr3" | grep -qF "$SUMMARY_LABEL"; then
        fail "13c: exit 3 fallback APPROVED does not route to $SUMMARY_LABEL (Summary) — clause: $appr3"
    elif enters_triage_or_present "$appr3"; then
        fail "13c: exit 3 fallback APPROVED (no concerns) must not enter Triage or Present — clause: $appr3"
    else
        pass "13c: exit 3 fallback APPROVED verdict routes to $SUMMARY_LABEL (Summary) only"
    fi
fi
case_end

# --- Setup for case 14: resolve the exit 0 branch line ---
line0="$(grep -E '^- exit 0 ' "$SKILL" 2>/dev/null || true)"

case_begin "exit-0-approved-routing" "skills/review-plan-security/SKILL.md"
# --- Normal case 14 (#2154): APPROVED (exit 0) skips triage and goes to Summary.
# Several '- exit 0' lines may exist (the RPS-3 block states "skips RPS-3"); all are checked together.
if [ -z "$line0" ]; then
    fail "14: no '- exit 0' branch line found in SKILL.md"
elif ! printf '%s' "$line0" | grep -qF "$SUMMARY_LABEL"; then
    fail "14: exit 0 branch does not route to the Summary step $SUMMARY_LABEL — line: $line0"
elif enters_triage_or_present "$line0"; then
    fail "14: exit 0 (no concerns) must not enter Triage or the Present step $PRESENT_LABEL — line: $line0"
else
    pass "14: exit 0 APPROVED branch routes to the Summary step $SUMMARY_LABEL only"
fi
case_end

case_begin "enters-triage-predicate-table" "skills/review-plan-security/SKILL.md"
# --- Adversarial 14b: the predicate itself must separate routing from a skip statement.
while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    input="${input# }"
    input="${input% }"
    got="clean"
    if enters_triage_or_present "$input"; then got="enters"; fi
    if [[ "$got" == "$want" ]]; then
        pass "14b/$name: '$input' -> $got"
    else
        fail "14b/$name: '$input' -> want=$want got=$got"
    fi
done <<'TABLE'
arrow-to-triage | - exit 0 APPROVED → RPS-3 | enters
arrow-to-present | - exit 0 → RPS-4 | enters
summary-then-present-via-triage | - exit 0 APPROVED → RPS-5; present via RPS-3 | enters
negated-skip-is-routing | - exit 0 does not skip RPS-3 | enters
skip-then-route-to-present | - exit 0 skips RPS-3 → RPS-4 | enters
summary-only | - exit 0 APPROVED → RPS-5 (no RISK items). | clean
explicit-skip-statement | - exit 0 carries no concerns and skips RPS-3. | clean
TABLE
case_end

case_begin "rps3-triage-block" "skills/review-plan-security/SKILL.md"
# --- Normal case 15 (#2154): RPS-3's body instructs a triage DECISION. ---
rps3_block="$(awk '/^RPS-3\./{f=1} f&&/^RPS-4\./{exit} f' "$SKILL" 2>/dev/null || true)"
if [ -z "$rps3_block" ]; then
    fail "15: no RPS-3 step block found in SKILL.md"
else
    r15=0
    printf '%s' "$rps3_block" | grep -qF 'skills/_shared/priority-hierarchy.md' \
        || { fail "15: RPS-3 block does not reference skills/_shared/priority-hierarchy.md"; r15=1; }
    printf '%s' "$rps3_block" | grep -qE 'reject' \
        || { fail "15: RPS-3 block states no reject disposition for a concern"; r15=1; }
    printf '%s' "$rps3_block" | grep -qE '(intent|outline|detail)\.md' \
        || { fail "15: RPS-3 block does not require citing the approved artifact (intent/outline/detail.md)"; r15=1; }
    printf '%s' "$rps3_block" | grep -qF "$PRESENT_LABEL" \
        || { fail "15: RPS-3 block does not forward the surviving (non-rejected) concerns to the Present step $PRESENT_LABEL"; r15=1; }
    if [ "$r15" -eq 0 ]; then pass "15: RPS-3 applies the hierarchy — reject disposition, cited artifact, survivors to $PRESENT_LABEL"; fi

    # 15b/15c/15d (#2154, CPR-ORTH with 16b/16c/16d)
    printf '%s' "$rps3_block" | grep -qE '([Rr]eject).*([Cc]ontradict|[Cc]onflict|[Rr]eopen|[Oo]verride)|([Cc]ontradict|[Cc]onflict|[Rr]eopen|[Oo]verride).*([Rr]eject)' \
        || { fail "15b: no RPS-3 line binds the reject disposition to the upstream-contradiction condition"; r15b=1; }
    rps3_uncond="$(printf '%s\n' "$rps3_block" | grep -nE '[Rr]eject' | grep -vE '[Cc]ontradict|[Cc]onflict|[Rr]eopen|[Oo]verride|priority-hierarchy|never|not grounds|survive|cited decision|procedure violation' || true)"
    [ -z "$rps3_uncond" ] \
        || { fail "15c: an RPS-3 line rejects concerns with no contradiction condition attached — line(s): $rps3_uncond"; r15b=1; }
    printf '%s' "$rps3_block" | grep -qE '(never|not|no).{0,40}(grounds|reason).{0,20}[Rr]eject|[Ss]urvives? triage|[Nn]ot .{0,30}reject' \
        || { fail "15d: RPS-3 states no carve-out — raising a topic the plan does not cover must NOT be grounds to reject"; r15b=1; }
    printf '%s\n' "$rps3_block" | grep -qE "([Ff]orward|[Ss]urviv|[Nn]ot rejected|[Rr]emaining).*$PRESENT_LABEL" \
        || { fail "15d: no RPS-3 line forwards the SURVIVING concerns to the Present step $PRESENT_LABEL — the label appears with no forwarding duty"; r15b=1; }
    if [ "${r15b:-0}" -eq 0 ]; then
        pass "15b/15c/15d: RPS-3 rejects ONLY on a cited contradiction, carries no unconditional disposition, and forwards survivors to $PRESENT_LABEL"
    fi
fi
case_end

# --- Setup for case 16/16d ---
PLAN_SEC_AGENT="$ROOT/agents/plan-security-reviewer.md"

case_begin "fallback-agent-hierarchy-and-procedure" "agents/plan-security-reviewer.md"
# --- Normal case 16 (#2154, CPR-ORTH with case 15): the fallback agent binds the
# hierarchy to a DISPOSITION inside its own ## Rules block. ---
# --- Normal case 16d: the REPORT side of the classifier. ---
if [ ! -f "$PLAN_SEC_AGENT" ]; then
    fail "16: agents/plan-security-reviewer.md not found"
else
    rules_block="$(awk '/^## Rules/{f=1;next} f&&/^## /{exit} f' "$PLAN_SEC_AGENT" 2>/dev/null || true)"
    if [ -z "$rules_block" ]; then
        fail "16: no '## Rules' block found in agents/plan-security-reviewer.md"
    else
        r16=0
        printf '%s' "$rules_block" | grep -qF 'skills/_shared/priority-hierarchy.md' \
            || { fail "16: Rules block does not reference skills/_shared/priority-hierarchy.md"; r16=1; }
        # Rules lines are imperative sentences, so the disposition verb can be
        # sentence-initial — match either case.
        printf '%s' "$rules_block" | grep -qE '[Rr]eject|[Ss]uppress' \
            || { fail "16: Rules block states no reject/suppress disposition for an upstream-contradicting concern"; r16=1; }
        printf '%s' "$rules_block" | grep -qE '(intent|outline|detail)\.md' \
            || { fail "16: Rules block does not name the approved artifact (intent/outline/detail.md) the concern must not contradict"; r16=1; }
        printf '%s' "$rules_block" | grep -qF 'RPS-3' \
            || { fail "16: Rules block does not point at SKILL.md RPS-3 as the canonical triage (CPR-SSOT)"; r16=1; }
        # C3 — BIND the disposition to its trigger.
        printf '%s' "$rules_block" | grep -qE '([Rr]eject|[Ss]uppress|not raise|Do not raise|not introduce).*([Cc]ontradict|[Cc]onflict|[Rr]eopen|[Oo]verride)|([Cc]ontradict|[Cc]onflict|[Rr]eopen|[Oo]verride).*([Rr]eject|[Ss]uppress|not raise|Do not raise|not introduce)' \
            || { fail "16b: no Rules line binds the suppress/reject disposition to the upstream-contradiction condition"; r16=1; }
        # And no OTHER line may carry the disposition unconditionally.
        unconditional="$(printf '%s\n' "$rules_block" | grep -nE '[Rr]eject|[Ss]uppress' | grep -vE '[Cc]ontradict|[Cc]onflict|[Rr]eopen|[Oo]verride|priority-hierarchy|RPS-3' || true)"
        [ -z "$unconditional" ] \
            || { fail "16c: a Rules line disposes of concerns with no contradiction condition attached — line(s): $unconditional"; r16=1; }
        # `[ ... ] && pass` would abort the whole run under `set -e` when r16=1,
        # hiding every later case; keep the failure local with a full if/fi.
        if [ "$r16" -eq 0 ]; then pass "16: fallback agent Rules block — hierarchy reference, disposition bound to the contradiction condition, cited artifact, RPS-3 pointer"; fi
    fi
    # 16d — the REPORT side of the classifier. Step 6 adds a Rules line and
    # leaves `## Procedure` untouched, so the duty to enumerate concerns that do
    # NOT contradict an upstream artifact must survive verbatim.
    proc_block="$(awk '/^## Procedure/{f=1;next} f&&/^## /{exit} f' "$PLAN_SEC_AGENT" 2>/dev/null || true)"
    r16d=0
    printf '%s' "$proc_block" | grep -qF 'NEEDS_REVISION' \
        || { fail "16d: Procedure no longer offers the NEEDS_REVISION verdict — non-contradicting concerns have nowhere to be reported"; r16d=1; }
    printf '%s' "$proc_block" | grep -qF '[HIGH]' \
        || { fail "16d: Procedure no longer enumerates severity-tagged concerns under NEEDS_REVISION"; r16d=1; }
    printf '%s' "$proc_block" | grep -qE 'Evaluate all three axes' \
        || { fail "16d: Procedure no longer requires evaluating all three security axes"; r16d=1; }
    if [ "$r16d" -eq 0 ]; then pass "16d: concerns that do not contradict an upstream artifact remain reportable (NEEDS_REVISION enumeration intact)"; fi
fi
case_end

case_begin "triage-precedes-present" "skills/review-plan-security/SKILL.md"
# --- Normal case 17 (#2154): Triage precedes Present in document order. ---
line_rps3="$(grep -nE '^RPS-3\.' "$SKILL" 2>/dev/null | head -1 | cut -d: -f1 || true)"
line_present="$PRESENT_LINE"
if [ -z "$line_rps3" ]; then
    fail "17: no RPS-3 step line found in SKILL.md"
elif [ -z "$line_present" ]; then
    fail "17: no RPS-n step line describing 'Present' found in SKILL.md"
elif [ "$line_rps3" -lt "$line_present" ]; then
    pass "17: Triage (RPS-3, line $line_rps3) precedes the Present step (line $line_present)"
else
    fail "17: Triage at line $line_rps3 does NOT precede the Present step at line $line_present"
fi
case_end

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
