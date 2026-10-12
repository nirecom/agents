#!/bin/bash
# tests/bin/feature-sweep-plans/skill.sh
# Tests: skills/sweep-plans/SKILL.md
# Tags: sweep, plans, workflow-plans, maintenance, skill, approval-gate, scope:common
#
# Static checks on the worktree's skills/sweep-plans/SKILL.md (K1-K3, K7) and the
# fixed vocabulary across the skill and bin/sweep-plans* (K6). Hub checks (K4, K5)
# live in tests/skills/feature-sweep-hub/plans-gate.sh. Runnable standalone:
#   bash tests/bin/feature-sweep-plans/skill.sh

# shellcheck source=_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

LOCAL_SKILL_MD="$__LIB_SCRIPT_CHECKOUT_ROOT/skills/sweep-plans/SKILL.md"

if [ ! -f "$LOCAL_SKILL_MD" ]; then
    fail "K0 skills/sweep-plans/SKILL.md exists"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

SKILL_TEXT="$(tr -d '\r' < "$LOCAL_SKILL_MD")"
FRONTMATTER="$(printf '%s\n' "$SKILL_TEXT" | awk 'NR==1 && $0=="---" {f=1; next} f && $0=="---" {exit} f {print}')"
BODY="$(printf '%s\n' "$SKILL_TEXT" | awk 'NR==1 && $0=="---" {f=1; next} f==1 && $0=="---" {f=2; next} f!=1 {print}')"

# K1 — the approval gate needs the parent conversation: no context: fork.
K1_frontmatter_no_fork() {
    if printf '%s\n' "$FRONTMATTER" | grep -qE '^context:[[:space:]]*fork[[:space:]]*$'; then
        fail "K1 frontmatter has no 'context: fork' (found)"
    else
        pass "K1 frontmatter has no 'context: fork'"
    fi
    if printf '%s\n' "$FRONTMATTER" | grep -qE '^user-invocable:[[:space:]]*true[[:space:]]*$'; then
        pass "K1 frontmatter keeps 'user-invocable: true'"
    else
        fail "K1 frontmatter keeps 'user-invocable: true'"
    fi
}

# K2 — the body names the script, the gate block, the human gate and every flag.
K2_body_names_protocol() {
    local needle
    for needle in 'bin/sweep-plans.sh' '<<<APPROVAL-GATE-SP3' 'AskUserQuestion' \
        '--gate-session' '--gate-id' '--approved-sessions-file' '--include-plan-and-user-requested'; do
        if printf '%s\n' "$BODY" | grep -qF -- "$needle"; then
            pass "K2 body contains $needle"
        else
            fail "K2 body contains $needle"
        fi
    done
}

# K3 — rules/prompt.md 1.6: no fenced code block of 3+ lines.
K3_no_fenced_block() {
    local longest
    longest="$(printf '%s\n' "$BODY" | awk '
        /^[[:space:]]*```/ { if (open) { n++; if (n > max) max = n; open = 0 } else { open = 1; n = 1 } ; next }
        open { n++ }
        END { if (open && n > max) max = n; print max + 0 }')"
    if [ "$longest" -ge 3 ]; then
        fail "K3 no fenced code block of 3+ lines (longest=$longest)"
    else
        pass "K3 no fenced code block of 3+ lines"
    fi
}

# K6 — fixed vocabulary: none of the retired words as whole words.
K6_vocabulary_fixed() {
    local targets=("$LOCAL_SKILL_MD" "$__LIB_SCRIPT_CHECKOUT_ROOT/bin/sweep-plans.sh")
    if [ -d "$__LIB_SCRIPT_CHECKOUT_ROOT/bin/sweep-plans" ]; then
        targets+=("$__LIB_SCRIPT_CHECKOUT_ROOT/bin/sweep-plans")
    fi
    local hits
    hits="$(grep -rniwE 'historical|record|noise|approval-required|auto-delete' "${targets[@]}" 2>/dev/null || true)"
    if [ -z "$hits" ]; then
        pass "K6 no retired vocabulary in the skill, bin/sweep-plans.sh or bin/sweep-plans/"
    else
        fail "K6 no retired vocabulary in the skill, bin/sweep-plans.sh or bin/sweep-plans/: $hits"
    fi
}

# K7 — SP-3 checks Other-typed tokens against the gate's token rows.
K7_sp3_checks_other_tokens() {
    local sp3
    sp3="$(printf '%s\n' "$BODY" | grep -E 'SP-3' | head -1)"
    if [ -z "$sp3" ]; then
        fail "K7 SP-3 step exists"
        return
    fi
    if printf '%s' "$sp3" | grep -qF 'Other' \
        && printf '%s' "$sp3" | grep -qiE '(check|match|verif|compar|validat)' \
        && printf '%s' "$sp3" | grep -qiE 'token' \
        && printf '%s' "$sp3" | grep -qiE '(gate|block)'; then
        pass "K7 SP-3 checks Other tokens against the gate rows"
    else
        fail "K7 SP-3 checks Other tokens against the gate rows: [$sp3]"
    fi
}

K1_frontmatter_no_fork
K2_body_names_protocol
K3_no_fenced_block
K6_vocabulary_fixed
K7_sp3_checks_other_tokens

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
