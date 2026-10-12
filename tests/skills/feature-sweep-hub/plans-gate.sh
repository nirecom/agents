#!/bin/bash
# Tests: skills/sweep/SKILL.md
# Tags: sweep, plans, approval-gate, hub, scope:common, TL1
# Part file of tests/skills/feature-sweep-hub.sh (sourced; uses its pass/fail and
# body_of helpers). K4/K5 pin the hub's side of the /sweep-plans approval gate:
# SW-3 describes the non-plan default scope, and the hub never adds or forwards
# --include-plan-and-user-requested, so hub runs never stop at the gate.

# K4 — SW-3 no longer says "deletes by default" and names the non-plan scope.
K4_sweep_hub_sw3_names_non_plan_scope() {
    if [ ! -f "$SWEEP_HUB" ]; then
        fail "K4 sweep_hub_sw3_names_non_plan_scope: $SWEEP_HUB does not exist"
        return
    fi
    local sw3
    sw3="$(tr -d '\r' < "$SWEEP_HUB" | grep -E '^SW-3\.' | head -1)"
    if [ -z "$sw3" ]; then
        fail "K4 sweep_hub_sw3_names_non_plan_scope: no SW-3 line"
        return
    fi
    case "$sw3" in
        *"deletes by default"*)
            fail "K4 sweep_hub_sw3_names_non_plan_scope: SW-3 still says 'deletes by default': $sw3" ;;
        *"non-plan"*)
            pass "K4 sweep_hub_sw3_names_non_plan_scope" ;;
        *)
            fail "K4 sweep_hub_sw3_names_non_plan_scope: SW-3 does not name 'non-plan': $sw3" ;;
    esac
}

# K5 — a hub rule forbids adding or forwarding --include-plan-and-user-requested.
K5_sweep_hub_never_forwards_include_flag() {
    if [ ! -f "$SWEEP_HUB" ]; then
        fail "K5 sweep_hub_never_forwards_include_flag: $SWEEP_HUB does not exist"
        return
    fi
    local body
    body="$(body_of "$SWEEP_HUB" | tr -d '\r')"
    if printf '%s\n' "$body" | grep -E -- '--include-plan-and-user-requested' \
        | grep -qiE '(never|not).*(add|forward)'; then
        pass "K5 sweep_hub_never_forwards_include_flag"
    else
        fail "K5 sweep_hub_never_forwards_include_flag: no line says the hub never adds/forwards --include-plan-and-user-requested"
    fi
}

K4_sweep_hub_sw3_names_non_plan_scope
K5_sweep_hub_never_forwards_include_flag
true
