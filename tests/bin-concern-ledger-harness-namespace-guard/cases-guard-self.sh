# shellcheck shell=bash
# Tests: tests/bin-concern-ledger-reducer/namespace-guard.sh
# Tags: concern-ledger, test-harness, namespace-guard, positive-control, TL2, scope:common, guard-self
# The guard's own entry points are a third watched set, distinct from the harness set and
# the library set. Directions A and B assume the guard is intact while it checks; a case
# file that defines clg_assert_harness_intact — by accident or by copy-paste — disarms the
# whole suite, and every G1/G3 case keeps passing because the disarmed guard reports
# nothing. Nothing above this file can see that, so it is checked here by name.

echo ""
echo "=== G11: the guard defends its own entry points ==="
# The verdict is read off nsg_emit, never off fail(): the clobbered name may BE the
# reporting path, so a check that reads $NSG_REPORT would grade the sabotage with the
# saboteur's own instrument (the same reason G1u exists).
expect_self_defense() {
    local label="$1" mode="$2" name="$3"
    run_scenario "$mode"
    case "$(nsg_verdict "$SC_OUT" "$mode")" in
        absent) fail "$label — the guard did not load, so no channel could carry the collision: $(brief "$SC_OUT")" ;;
        incomplete) fail "$label — the scenario never reached NSG-DONE=$mode (rc=$SC_RC); it died before the sibling assert returned, so nothing here is a verdict: $(brief "$SC_OUT")" ;;
        no-verdict) fail "$label — $name was clobbered and every guard-owned channel came back empty. A guard that watches the harness and the library but not itself is switched off by one line in a case file, silently: $(brief "$SC_OUT")" ;;
        *) if printf '%s\n' "$SC_OUT" | grep -E '^NSG-LAST=' | grep -Fq -- "$name"; then
               pass "$label"
           else
               fail "$label — a collision surfaced but CLG_LAST_REPORT never names $name, so the guard fired on something else and this case would pass on the wrong evidence: $(brief "$SC_OUT")"
           fi ;;
    esac
}

for _g in clg_assert_harness_intact clg_assert_library_intact clg_snapshot_before clg_record_library_names; do
    expect_self_defense "G11o/$_g: overwriting the guard's own $_g is reported" "G11o-$_g" "$_g"
    expect_self_defense "G11z/$_g: unsetting the guard's own $_g is reported" "G11z-$_g" "$_g"
done

# G11n — the negative control the eight above are meaningless without. A guard that
# reported its own names unconditionally would pass every G11o/G11z row while saying
# nothing about tampering, so an untouched guard must leave the same channels empty.
run_scenario G11n
case "$(nsg_verdict "$SC_OUT" G11n)" in
    absent) fail "G11n: the guard did not load, so the negative control has nothing to observe: $(brief "$SC_OUT")" ;;
    incomplete) fail "G11n: the scenario never reached NSG-DONE=G11n (rc=$SC_RC): $(brief "$SC_OUT")" ;;
    no-verdict) if [[ -n "$SC_COLLISION" ]]; then
                    fail "G11n: the guard-owned channels stayed empty but a collision line still reached stdout: $(brief "$SC_COLLISION")"
                elif [[ -n "$SC_REPORT" ]]; then
                    fail "G11n: the guard-owned channels stayed empty but fail() still received: $(brief "$SC_REPORT")"
                else
                    pass "G11n: an untouched guard leaves its own entry points unreported"
                fi ;;
    *) fail "G11n: nothing was clobbered, yet the guard raised a verdict on its own names — G11o/G11z would then pass on a guard that reports unconditionally: $(brief "$SC_OUT")" ;;
esac
