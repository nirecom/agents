#!/bin/bash
# tests/feature-920-companion-issues/b-series.sh
# Tests: skills/workflow-init/SKILL.md, skills/clarify-intent/SKILL.md, bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/wip-check.js
# Tags: companion-issues, workflow-init, clarify-intent, scope:issue-specific
#
# B-series: SKILL.md prose contracts — WI-5 deletion + CI-2b update (reason
# field + own search). The workflow-init driver rewrite moved the aggregate
# WIP check (B2) and the non-GitHub gate (B9) from SKILL.md step prose into
# bin/workflow/workflow-init-driver + lib phases; those assertions target the
# driver sources now.
#
# L3 gap (what these tests do NOT catch):
# - Whether workflow-init or clarify-intent actually invoke the companion-search
#   script at runtime inside a live Claude Code session.
# - Whether AskUserQuestion renders the reason field correctly in the dialog UI.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# B1: WI-5 is gone — no "Companion-issue detection" heading; no
# find-companion-issues.sh reference remains in workflow-init.
if [ -f "$WORKFLOW_INIT_SKILL" ]; then
    has_heading=0
    has_script=0
    if grep -q "Companion-issue detection" "$WORKFLOW_INIT_SKILL"; then has_heading=1; fi
    if grep -q "find-companion-issues.sh" "$WORKFLOW_INIT_SKILL"; then has_script=1; fi
    if [ "$has_heading" -eq 0 ] && [ "$has_script" -eq 0 ]; then
        pass "B1: workflow-init no longer references companion-issue detection (WI-5 removed)"
    else
        fail "B1: workflow-init still contains WI-5 artefacts (heading=$has_heading script=$has_script)"
    fi
else
    fail "B1: workflow-init SKILL.md not found"
fi

# B2: Aggregate WIP check — the former WI-5 step prose moved into the driver
# phase bin/workflow/lib/workflow-init/phases/wip-check.js (workflow-init
# driver rewrite). Protected concept unchanged: the aggregate classification
# (any_other → conflict ask / ALL_NONE → fresh claim + Path B force) exists,
# and SKILL.md WI-2 names "Aggregate WIP check" as the WIP entry point.
WIP_PHASE="$AGENTS_DIR/bin/workflow/lib/workflow-init/phases/wip-check.js"
if [ -f "$WIP_PHASE" ] && [ -f "$WORKFLOW_INIT_SKILL" ]; then
    a=0; b=0; c=0; d=0
    grep -qF "Aggregate WIP check" "$WORKFLOW_INIT_SKILL" && a=1
    grep -qF 'askId: "wip_conflict"' "$WIP_PHASE" && b=1
    grep -qF "noneIssues.length === issues.length" "$WIP_PHASE" && c=1
    grep -qF "force_path_b" "$WIP_PHASE" && d=1
    if [ "$a" -eq 1 ] && [ "$b" -eq 1 ] && [ "$c" -eq 1 ] && [ "$d" -eq 1 ]; then
        pass "B2: aggregate WIP check lives in wip-check.js and SKILL.md WI-2 names it"
    else
        fail "B2: aggregate WIP check incomplete (skill=$a conflict=$b all-none=$c force-b=$d)"
    fi
else
    fail "B2: wip-check.js or workflow-init SKILL.md not found"
fi

# B3: WI-13 must NOT exist any more (max is WI-12 post-renumber).
if [ -f "$WORKFLOW_INIT_SKILL" ]; then
    if grep -qE "^### Step WI-13 " "$WORKFLOW_INIT_SKILL"; then
        fail "B3: WI-13 still present (renumber not applied)"
    else
        pass "B3: WI-13 gone (max step is WI-12 after renumber)"
    fi
else
    fail "B3: workflow-init SKILL.md not found"
fi

# B4: CI-2b contains both 'reason' AND 'Reason:' (for AskUserQuestion rendering)
if [ -f "$CLARIFY_INTENT_SKILL" ]; then
    CI2B_BLOCK=$(awk '/CI-2b\./{flag=1} flag && /^CI-[0-9]+[a-z]?\./ && !/CI-2b\./{flag=0} flag' "$CLARIFY_INTENT_SKILL" 2>/dev/null || true)
    has_reason_lc=0
    has_reason_cap=0
    if echo "$CI2B_BLOCK" | grep -q "reason"; then has_reason_lc=1; fi
    if echo "$CI2B_BLOCK" | grep -q "Reason:"; then has_reason_cap=1; fi
    if [ "$has_reason_lc" -eq 1 ] && [ "$has_reason_cap" -eq 1 ]; then
        pass "B4: CI-2b includes 'reason' and 'Reason:' (AskUserQuestion render)"
    else
        fail "B4: CI-2b missing reason fields (lc=$has_reason_lc cap=$has_reason_cap)"
    fi
else
    fail "B4: clarify-intent SKILL.md not found"
fi

# B5: CI-2b mentions companion-search.sh, --exclude, closes_issues
# (find-companion-issues.sh is now inside companion-search.sh, not referenced directly)
if [ -f "$CLARIFY_INTENT_SKILL" ]; then
    CI2B_BLOCK=$(awk '/CI-2b\./{flag=1} flag && /^CI-[0-9]+[a-z]?\./ && !/CI-2b\./{flag=0} flag' "$CLARIFY_INTENT_SKILL" 2>/dev/null || true)
    a=0; b=0; c=0
    echo "$CI2B_BLOCK" | grep -q "companion-search.sh" && a=1
    echo "$CI2B_BLOCK" | grep -q -- "--exclude" && b=1
    echo "$CI2B_BLOCK" | grep -q "closes_issues" && c=1
    if [ "$a" -eq 1 ] && [ "$b" -eq 1 ] && [ "$c" -eq 1 ]; then
        pass "B5: CI-2b references companion-search.sh + --exclude + closes_issues"
    else
        fail "B5: CI-2b missing pieces (script=$a exclude=$b closes=$c)"
    fi
else
    fail "B5: clarify-intent SKILL.md not found"
fi

# B6: companion-search.sh handles GitHub gate; CI-2b has no CONFIRM_COMPANION_ISSUES reference.
if [ -f "$CLARIFY_INTENT_SKILL" ]; then
    CI2B_BLOCK=$(awk '/CI-2b\./{flag=1} flag && /^CI-[0-9]+[a-z]?\./ && !/CI-2b\./{flag=0} flag' "$CLARIFY_INTENT_SKILL" 2>/dev/null || true)
    COMPANION_SCRIPT="$AGENTS_DIR/skills/clarify-intent/scripts/companion-search.sh"
    a=0; b=0
    { [ -f "$COMPANION_SCRIPT" ] && grep -qE "is-github-dotcom-remote|NON_GITHUB" "$COMPANION_SCRIPT"; } && a=1
    echo "$CI2B_BLOCK" | grep -q "CONFIRM_COMPANION_ISSUES" || b=1
    if [ "$a" -eq 1 ] && [ "$b" -eq 1 ]; then
        pass "B6: companion-search.sh has GitHub gate; CI-2b has no CONFIRM_COMPANION_ISSUES reference"
    else
        fail "B6: incomplete (script-gate=$a confirm-absent=$b)"
    fi
else
    fail "B6: clarify-intent SKILL.md not found"
fi

# B7: clarify-intent must NOT reference 'WI-5 acceptances' any more.
if [ -f "$CLARIFY_INTENT_SKILL" ]; then
    if grep -q "WI-5 acceptances" "$CLARIFY_INTENT_SKILL"; then
        fail "B7: clarify-intent still mentions 'WI-5 acceptances'"
    else
        pass "B7: clarify-intent no longer mentions WI-5 acceptances"
    fi
else
    fail "B7: clarify-intent SKILL.md not found"
fi

# B8: WI-12 present AND WI-13 absent (post-renumber bounds).
if [ -f "$WORKFLOW_INIT_SKILL" ]; then
    a=0; b=0
    grep -qE "^### Step WI-12 " "$WORKFLOW_INIT_SKILL" && a=1
    grep -qE "^### Step WI-13 " "$WORKFLOW_INIT_SKILL" || b=1
    if [ "$a" -eq 1 ] && [ "$b" -eq 1 ]; then
        pass "B8: WI-12 present, WI-13 absent (post-renumber)"
    else
        fail "B8: bounds wrong (WI-12=$a WI-13-absent=$b)"
    fi
else
    fail "B8: workflow-init SKILL.md not found"
fi

# B10: CI-2b contains no get-config-var call — CONFIRM_COMPANION_ISSUES removal is complete.
if [ -f "$CLARIFY_INTENT_SKILL" ]; then
    CI2B_BLOCK=$(awk '/CI-2b\./{flag=1} flag && /^CI-[0-9]+[a-z]?\./ && !/CI-2b\./{flag=0} flag' "$CLARIFY_INTENT_SKILL" 2>/dev/null || true)
    if echo "$CI2B_BLOCK" | grep -q "get-config-var"; then
        fail "B10: CI-2b still references get-config-var (CONFIRM_COMPANION_ISSUES helper lingered)"
    else
        pass "B10: CI-2b has no get-config-var reference"
    fi
else
    fail "B10: clarify-intent SKILL.md not found"
fi

# B9: WI-2 non-GitHub gate — the step-range prose ("skip WI-3..WI-8, run
# WI-9..WI-12 normally") moved into the driver entrypoint
# bin/workflow/workflow-init-driver (workflow-init driver rewrite). Protected
# concept unchanged: NON_GITHUB=1 short-circuits the gh-dependent phases but
# still writes context.md and emits done/Path C; SKILL.md documents the
# NON_GITHUB=1 → Path C routing.
DRIVER_BIN="$AGENTS_DIR/bin/workflow/workflow-init-driver"
if [ -f "$DRIVER_BIN" ] && [ -f "$WORKFLOW_INIT_SKILL" ]; then
    a=0; b=0; c=0
    grep -qF 'process.env.NON_GITHUB === "1"' "$DRIVER_BIN" && a=1
    NONGH_BLOCK=$(awk '/if \(nonGithub\) \{/{flag=1} flag{print} flag && /^  \}/{flag=0}' "$DRIVER_BIN" 2>/dev/null || true)
    if echo "$NONGH_BLOCK" | grep -q "writeContext" \
        && echo "$NONGH_BLOCK" | grep -qF 'emitDone(ckptFile, "C")'; then b=1; fi
    grep -qF "NON_GITHUB=1" "$WORKFLOW_INIT_SKILL" && c=1
    if [ "$a" -eq 1 ] && [ "$b" -eq 1 ] && [ "$c" -eq 1 ]; then
        pass "B9: NON_GITHUB gate short-circuits driver to done/Path C (context.md still written)"
    else
        fail "B9: NON_GITHUB gate incomplete (env-gate=$a short-circuit=$b skill-doc=$c)"
    fi
else
    fail "B9: workflow-init-driver or workflow-init SKILL.md not found"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
