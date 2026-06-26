#!/bin/bash
# tests/feature-920-companion-issues/c-d-series.sh
# Tests: skills/clarify-intent/SKILL.md, .env.example
# Tags: companion-issues, clarify-intent, env-example, scope:issue-specific
#
# C-series: prefill #N regex preservation + WI-5 stale-pointer scrub.
# D-series: CONFIRM_COMPANION_ISSUES fully removed from .env.example,
# companion-search.sh, and CI-2b (no auto-accept mode).
#
# L3 gap (what these tests do NOT catch):
# - Whether the updated .env.example comment causes any runtime behaviour change
#   (it is documentation only; any breakage would be in the consuming code).
# - Whether CI-2b's AskUserQuestion text renders correctly in a live session.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# C1: prefill #N regex match — preserves CI-1a auto-detect contract.
CTMP="$(mktemp -d 2>/dev/null || mktemp -d -t prefill)"
PREFILL="$CTMP/issue-prefill.md"
cat > "$PREFILL" <<'PREFILL_EOF'
## Companion #905
Related: #905
PREFILL_EOF
CONTENT="$(cat "$PREFILL")"
MATCH_NUM=""
if [[ "$CONTENT" =~ \#([0-9]+) ]]; then
    MATCH_NUM="${BASH_REMATCH[1]}"
fi
if [ "$MATCH_NUM" = "905" ]; then
    pass "C1: prefill format yields #905 via bash regex"
else
    fail "C1: expected #905 regex match; got '$MATCH_NUM'"
fi
rm -rf "$CTMP" 2>/dev/null || true

# C2: clarify-intent has no stale 'WI-5 accepted' or 'issue-prefill.md'
# companion-pointer references — CI-2b now does its own search.
if [ -f "$CLARIFY_INTENT_SKILL" ]; then
    a=0; b=0
    grep -q "WI-5 accepted" "$CLARIFY_INTENT_SKILL" || a=1
    grep -q "issue-prefill.md" "$CLARIFY_INTENT_SKILL" || b=1
    if [ "$a" -eq 1 ] && [ "$b" -eq 1 ]; then
        pass "C2: clarify-intent contains no stale WI-5 / issue-prefill.md pointers"
    else
        fail "C2: stale pointer found (WI-5-absent=$a prefill-absent=$b)"
    fi
else
    fail "C2: clarify-intent SKILL.md not found"
fi

# D1: CONFIRM_COMPANION_ISSUES absent from .env.example (removed in #968).
if [ -f "$ENV_EXAMPLE" ]; then
    if grep -qE '^CONFIRM_COMPANION_ISSUES\b' "$ENV_EXAMPLE"; then
        fail "D1: .env.example still contains CONFIRM_COMPANION_ISSUES (removal not applied)"
    else
        pass "D1: CONFIRM_COMPANION_ISSUES absent from .env.example"
    fi
else
    fail "D1: .env.example not found"
fi

# D2: companion-search.sh has no CONFIRM_COMPANION_ISSUES reference.
COMPANION_SCRIPT="$AGENTS_DIR/skills/clarify-intent/scripts/companion-search.sh"
if [ -f "$COMPANION_SCRIPT" ]; then
    if grep -q "CONFIRM_COMPANION_ISSUES" "$COMPANION_SCRIPT"; then
        fail "D2: companion-search.sh still references CONFIRM_COMPANION_ISSUES"
    else
        pass "D2: companion-search.sh has no CONFIRM_COMPANION_ISSUES reference"
    fi
else
    fail "D2: companion-search.sh not found"
fi

# D3: CI-2b in clarify-intent has no 'Exit 2' auto-accept path.
if [ -f "$CLARIFY_INTENT_SKILL" ]; then
    CI2B_BLOCK=$(awk '/CI-2b\./{flag=1} flag && /^CI-[0-9]+[a-z]?\./ && !/CI-2b\./{flag=0} flag' "$CLARIFY_INTENT_SKILL" 2>/dev/null || true)
    if echo "$CI2B_BLOCK" | grep -q "Exit 2"; then
        fail "D3: CI-2b still references 'Exit 2' auto-accept (CONFIRM_COMPANION_ISSUES not removed)"
    else
        pass "D3: CI-2b has no 'Exit 2' auto-accept path"
    fi
else
    fail "D3: clarify-intent SKILL.md not found"
fi

# --- #1117 static assertions (RED until SKILL.md prose lands) ----------------
# Helper: extract the CI-2b companion-accept block from clarify-intent SKILL.md.
ci2b_block() {
    awk '/CI-2b\./{flag=1} flag && /^CI-[0-9]+[a-z]?\./ && !/CI-2b\./{flag=0} flag' \
        "$CLARIFY_INTENT_SKILL" 2>/dev/null || true
}

# D4: CI-2b accept block references wip-set-single.sh — accepting a companion
# issue claims its WIP immediately (#1117 Step 2).
if [ -f "$CLARIFY_INTENT_SKILL" ]; then
    if ci2b_block | grep -q "wip-set-single.sh"; then
        pass "D4: CI-2b references wip-set-single.sh (immediate WIP claim on accept)"
    else
        fail "D4: CI-2b does not reference wip-set-single.sh — accepted companion not claimed early"
    fi
else
    fail "D4: clarify-intent SKILL.md not found"
fi

# D5: WI-3 references filter-primary-candidates.sh (#1117 Step 4 — CLOSED+parent
# primary-candidate filter). The reference may live in WI-3 or its body prose;
# assert the script name appears in workflow-init SKILL.md.
if [ -f "$WORKFLOW_INIT_SKILL" ]; then
    if grep -q "filter-primary-candidates.sh" "$WORKFLOW_INIT_SKILL"; then
        pass "D5: workflow-init SKILL.md references filter-primary-candidates.sh"
    else
        fail "D5: workflow-init SKILL.md does not reference filter-primary-candidates.sh"
    fi
else
    fail "D5: workflow-init SKILL.md not found"
fi

# D6: WI-5 ALL_NONE NEEDS_CLARIFY (Exit 1) branch no longer says "skip WIP" as a
# definitive statement — early claim now happens in wip-set-resume.sh (#1117
# Step 1). The Exit 2 RC2 branch may still legitimately say "skip WIP,
# acknowledge risk", so isolate just the Exit-1 segment (between `Exit 1` and
# `Exit 2`) of the ALL_NONE bullet.
if [ -f "$WORKFLOW_INIT_SKILL" ]; then
    ALL_NONE_BULLET=$(grep -E '^- `ALL_NONE`' "$WORKFLOW_INIT_SKILL" | head -1 || true)
    EXIT1_SEG=$(printf '%s' "$ALL_NONE_BULLET" | sed -E 's/.*Exit 1//; s/Exit 2.*//')
    if [ -z "$ALL_NONE_BULLET" ]; then
        fail "D6: WI-5 ALL_NONE bullet not found in workflow-init SKILL.md"
    elif printf '%s' "$EXIT1_SEG" | grep -qi "skip WIP"; then
        fail "D6: WI-5 ALL_NONE Exit-1 branch still says 'skip WIP' definitively; seg='$EXIT1_SEG'"
    else
        pass "D6: WI-5 ALL_NONE Exit-1 branch no longer says 'skip WIP' definitively"
    fi
else
    fail "D6: workflow-init SKILL.md not found"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
