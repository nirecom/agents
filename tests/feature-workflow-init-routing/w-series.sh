#!/bin/bash
# tests/feature-workflow-init-routing/w-series.sh
# Tests: skills/workflow-init/SKILL.md
# Tags: workflow, init, routing, multi-n, scope:common
#
# W-series: Issue #444 (multi-N closes_issues) and Issue #797 (all-N routing)
# content assertions (W5-W14).

set -uo pipefail

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

echo "=== Issue #444: workflow-init multi-N ==="
echo ""

# W5: SKILL.md no longer contains 'Move the selected entry to index 0'; ISSUES= still present (insertion order).
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W5: workflow-init insertion-order semantics check (file not found)"
elif grep -qE "ISSUES=" "$WORKFLOW_INIT_MD" && ! grep -qF "Move the selected entry to index 0" "$WORKFLOW_INIT_MD"; then
    pass "W5: SKILL.md retains ISSUES= and no longer contains 'Move the selected entry to index 0' (insertion order)"
else
    fail "W5: SKILL.md must retain ISSUES= AND must NOT contain 'Move the selected entry to index 0'"
fi

# W6: The 2+ branch is followed by AskUserQuestion reference; `pick one` is absent.
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W6a: 2+ branch references AskUserQuestion (file not found)"
else
    PLUS_LN=$(grep -nE "2\+" "$WORKFLOW_INIT_MD" | head -1 | cut -d: -f1 || true)
    if [ -n "$PLUS_LN" ]; then
        END_LN=$((PLUS_LN + 50))
        SLICE=$(awk -v s="$PLUS_LN" -v e="$END_LN" 'NR>=s && NR<=e' "$WORKFLOW_INIT_MD")
        if printf '%s' "$SLICE" | grep -qF "AskUserQuestion"; then
            pass "W6a: 2+ branch is followed by AskUserQuestion reference within 50 lines"
        else
            fail "W6a: 2+ branch (line $PLUS_LN) not followed by AskUserQuestion within 50 lines"
        fi
    else
        fail "W6a: no '2+' marker found in SKILL.md"
    fi
fi
assert_absent_local "$WORKFLOW_INIT_MD" "pick one" \
    "W6b: 'pick one' (old narrowing behavior) is absent from SKILL.md"

# W7: Path A section documents multi-issue closes_issues (ISSUES[1+] present).
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W7: Path A multi-issue documentation (file not found)"
else
    PATH_A_W7=$(awk '/^#### Path A/{in_a=1;next} in_a{if(/^#### /){exit}print}' "$WORKFLOW_INIT_MD")
    if printf '%s' "$PATH_A_W7" | grep -qF 'ISSUES[1+]'; then
        pass "W7: Path A documents multi-issue closes_issues (ISSUES[1+] present)"
    else
        fail "W7: Path A missing multi-issue documentation (ISSUES[1+] not found)"
    fi
fi

# W8: SKILL.md Step 1 mentions ISSUES[0], closes_issues[0], and 'becomes closes_issues[0]'.
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W8: index-zero mappings (file not found)"
elif grep -qE "ISSUES\[0\]" "$WORKFLOW_INIT_MD" \
  && grep -qE "closes_issues\[0\]" "$WORKFLOW_INIT_MD" \
  && grep -qF "becomes closes_issues[0]" "$WORKFLOW_INIT_MD"; then
    pass "W8: SKILL.md mentions ISSUES[0], closes_issues[0], and 'becomes closes_issues[0]'"
else
    fail "W8: SKILL.md must contain 'ISSUES[0]', 'closes_issues[0]', and 'becomes closes_issues[0]'"
fi

# W9: literal 'AskUserQuestion to pick one' must be absent (regression prevention).
assert_absent_local "$WORKFLOW_INIT_MD" "AskUserQuestion to pick one" \
    "W9: 'AskUserQuestion to pick one' old narrowing prompt is absent"

# W10: Path A section fail-closed regression prevention.
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W10: Path A fail-closed regression prevention (file not found)"
else
    PATH_A_SLICE=$(awk '
        /^#### Path A/ { in_a = 1 }
        in_a {
            if (/^#### Path [BC]/) { exit }
            print
        }
    ' "$WORKFLOW_INIT_MD")
    if printf '%s' "$PATH_A_SLICE" | grep -qF "ABORT" \
       && printf '%s' "$PATH_A_SLICE" | grep -qF -- '--add-label "intent:clarified"' \
       && printf '%s' "$PATH_A_SLICE" | grep -qF "aborted-pathA-multiN-label-failure"; then
        pass "W10a: Path A section contains ABORT, --add-label \"intent:clarified\", and aborted-pathA-multiN-label-failure"
    else
        fail "W10a: Path A section missing one of: ABORT / --add-label \"intent:clarified\" / aborted-pathA-multiN-label-failure"
    fi
    if printf '%s' "$PATH_A_SLICE" | grep -qF "continuing]"; then
        fail "W10b: Path A fail-open pattern 'continuing]' unexpectedly present"
    else
        pass "W10b: Path A fail-open pattern 'continuing]' is absent"
    fi
fi

# W12: WI-4 text covers all-N fetch (loop over all ISSUES, not primary-only).
echo ""
echo "--- Issue #797: all-N routing assertions ---"

if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W12: WI-4 all-N fetch check (file not found)"
else
    if grep -qE "for each N in .ISSUES|ISSUES\[@\].*gh issue view|gh issue view.*ISSUES\[@\]|loop.*ISSUES|each.*N.*fetch" "$WORKFLOW_INIT_MD"; then
        pass "W12a: WI-4 contains all-N fetch pattern"
    else
        fail "W12a: WI-4 must reference all-N fetch pattern (ISSUES[@] loop or similar)"
    fi
    assert_absent_local "$WORKFLOW_INIT_MD" "from the primary's \`gh issue view\`" \
        "W12b: WI-4 no longer has primary-only fetch reference in label-extract context"
fi

# W13: WI-7 label extraction is per-N (not from primary's JSON).
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W13: WI-7 per-N label extract (file not found)"
else
    assert_absent_local "$WORKFLOW_INIT_MD" "from the primary's \`gh issue view\` JSON" \
        "W13: WI-7 no longer extracts labels from the primary's gh issue view JSON only"
fi

# W14: WI-8 routing predicate covers all N (not just primary).
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W14: WI-8 all-N predicate (file not found)"
else
    if grep -qE "ALL N|all N|intent:clarified.*every N|every N.*intent:clarified" "$WORKFLOW_INIT_MD"; then
        pass "W14a: WI-8 contains all-N routing predicate"
    else
        fail "W14a: WI-8 must contain all-N routing predicate (ALL N or every N)"
    fi
    assert_absent_local "$WORKFLOW_INIT_MD" "labels of primary" \
        "W14b: WI-8 no longer routes on 'labels of primary'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
