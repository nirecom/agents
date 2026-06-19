#!/bin/bash
# tests/feature-920-companion-issues/c-d-series.sh
# Tests: skills/clarify-intent/SKILL.md, .env.example
# Tags: companion-issues, clarify-intent, env-example, scope:issue-specific
#
# C-series: prefill #N regex preservation + WI-5 stale-pointer scrub.
# D-series: .env.example CONFIRM_COMPANION_ISSUES 3-section comment +
# 3-pass detection-signal mention.
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

# D1: CONFIRM_COMPANION_ISSUES has default=on and 3-section comment structure.
if [ -f "$ENV_EXAMPLE" ]; then
    LINE_NO=$(grep -nE '^CONFIRM_COMPANION_ISSUES\b' "$ENV_EXAMPLE" | head -1 | cut -d: -f1 || true)
    if [ -z "$LINE_NO" ]; then
        fail "D1: .env.example missing CONFIRM_COMPANION_ISSUES directive"
    else
        DIRECTIVE=$(sed -n "${LINE_NO}p" "$ENV_EXAMPLE")
        START=$((LINE_NO > 15 ? LINE_NO - 15 : 1))
        BEFORE=$(sed -n "${START},${LINE_NO}p" "$ENV_EXAMPLE")
        d=0; c=0; n=0; f=0
        echo "$DIRECTIVE" | grep -qE "=on\b|=\"on\"|='on'" && d=1
        echo "$BEFORE" | grep -qiE "(what you can do|you can do|able to)" && c=1
        echo "$BEFORE" | grep -qiE "(can't do|cannot do|does NOT|does not|won't|not changed)" && n=1
        echo "$BEFORE" | grep -qiE "(format|example|values?:|syntax)" && f=1
        if [ "$d" -eq 1 ] && [ "$c" -eq 1 ] && [ "$n" -eq 1 ] && [ "$f" -eq 1 ]; then
            pass "D1: CONFIRM_COMPANION_ISSUES default=on + 3-section comment present"
        else
            fail "D1: CONFIRM_COMPANION_ISSUES incomplete (on=$d can=$c cant=$n fmt=$f)"
        fi
    fi
else
    fail "D1: .env.example not found"
fi

# D2: comment block does NOT mention 'search algorithm' — capture comment
# lines into a variable, then assert on the captured text (not via pipe-negation).
if [ -f "$ENV_EXAMPLE" ]; then
    LINE_NO=$(grep -nE '^CONFIRM_COMPANION_ISSUES\b' "$ENV_EXAMPLE" | head -1 | cut -d: -f1 || true)
    if [ -z "$LINE_NO" ]; then
        fail "D2: .env.example missing CONFIRM_COMPANION_ISSUES directive"
    else
        START=$((LINE_NO > 15 ? LINE_NO - 15 : 1))
        BEFORE=$(sed -n "${START},${LINE_NO}p" "$ENV_EXAMPLE")
        if echo "$BEFORE" | grep -q "search algorithm"; then
            fail "D2: comment still references stale 'search algorithm' phrase"
        else
            pass "D2: comment block does not mention 'search algorithm'"
        fi
    fi
else
    fail "D2: .env.example not found"
fi

# D3: comment block references the 3-pass detection signals (xref / identifier / sibling).
if [ -f "$ENV_EXAMPLE" ]; then
    LINE_NO=$(grep -nE '^CONFIRM_COMPANION_ISSUES\b' "$ENV_EXAMPLE" | head -1 | cut -d: -f1 || true)
    if [ -z "$LINE_NO" ]; then
        fail "D3: .env.example missing CONFIRM_COMPANION_ISSUES directive"
    else
        START=$((LINE_NO > 15 ? LINE_NO - 15 : 1))
        BEFORE=$(sed -n "${START},${LINE_NO}p" "$ENV_EXAMPLE")
        x=0; i=0; s=0
        echo "$BEFORE" | grep -qiE "(xref|cross.?reference)" && x=1
        echo "$BEFORE" | grep -qiE "(identifier|ident:)" && i=1
        echo "$BEFORE" | grep -qiE "(sibling)" && s=1
        if [ "$x" -eq 1 ] && [ "$i" -eq 1 ] && [ "$s" -eq 1 ]; then
            pass "D3: comment block references xref + identifier + sibling signals"
        else
            fail "D3: 3-pass signals incomplete (xref=$x ident=$i sibling=$s)"
        fi
    fi
else
    fail "D3: .env.example not found"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
