# shellcheck shell=bash
# Tests: tests/bin-concern-ledger-reducer/namespace-guard.sh
# Tags: concern-ledger, test-harness, namespace-guard, positive-control, TL2, scope:common, direction-a
# Direction A — the library (or anything sourced after it) shadowing a harness name.
# Every check is a positive/negative control pair, because a guard that never fires is
# indistinguishable from no guard at all.

echo ""
echo "=== direction A: library over harness ==="
expect_report "G1: a harness function overwritten after the snapshot is reported" \
    G1 "hx_probe" "ctx-G1"
expect_silent "G2: sourcing a well-behaved library leaves direction A silent" G2
# G1v/G1w/G2v — the scalar half of direction A. clg_snapshot_before retains function
# bodies AND the named scalars (PASS FAIL AGENTS_ROOT LIB CLI TMPDIR_BASE WORK
# SUITE_DIR); G1/G2 move only a function, so a functions-only guard passes them both.
# WORK and PASS are the two the guard's own bookkeeping never reads.
expect_report "G1v: a harness scalar (WORK) changed after the snapshot is reported" \
    G1v "WORK" "ctx-G1v"
expect_report "G1w: a harness scalar (PASS) changed after the snapshot is reported" \
    G1w "PASS" "ctx-G1w"
expect_silent "G2v: re-assigning the same scalar values leaves direction A silent" G2v
# G1s — the rest of the retained set, table-driven (CPR-ORTH with G7c on the library
# side). G1v/G1w pin two names; a guard that watches only those two lets the other six
# drift, and the six below are exactly the ones a case file would corrupt to make the
# harness read the wrong root, the wrong library, or the wrong temp tree while the
# banner still prints a clean verdict. FAIL is here because a case file that resets the
# counter turns a red suite green with no other trace.
for _hs in FAIL AGENTS_ROOT LIB CLI TMPDIR_BASE SUITE_DIR; do
    expect_report "G1s/$_hs: the harness scalar $_hs is in the retained set and its change is reported" \
        "G1s-$_hs" "$_hs" "ctx-G1s-$_hs"
done
# G1x/G1y/G2x — the reporting primitives themselves. hx_probe is a stand-in; pass()
# and fail() are what the whole suite's verdict rests on. A case file that redefines
# either one makes every later assertion report into the void while the banner still
# reads "All tests passed", so direction A must cover them by name, not by analogy.
expect_report "G1x: overwriting the harness pass() is reported" \
    G1x "pass" "ctx-G1x"
expect_report "G1y: overwriting the harness fail() is reported" \
    G1y "fail" "ctx-G1y"
expect_silent "G2x: re-defining pass()/fail() with identical bodies leaves direction A silent" G2x

# G1u — the attack the report path is hardened against, and the reason $NSG_REPORT is no
# longer anyone's evidence. `fail` is itself a harness name, so a case file that writes
# `fail() { :; }` used to swallow the guard's OWN report and take the suite green on a
# namespace it had already detected as broken. Three claims are graded here: a guard-owned
# channel fired; the collision reached stdout naming the clobbered name; and the FAIL
# counter the dispatcher's banner is computed from actually moved. The last is what makes
# the printed line a verdict rather than a comment.
run_scenario G1u
case "$(nsg_verdict "$SC_OUT" G1u)" in
    absent) fail "G1u: the guard did not load, so no channel could carry the collision: $(brief "$SC_OUT")" ;;
    incomplete) fail "G1u: the scenario never reached NSG-DONE=G1u (rc=$SC_RC) — it died before the assert returned, so nothing here is a verdict about the guard: $(brief "$SC_OUT")" ;;
    no-verdict) fail "G1u: fail() replaced by a complete no-op and every guard-owned channel came back empty — NSG-RC=0, no CLG_REPORT_COUNT, no CLG_LAST_REPORT. A guard that reports only through fail() is silent here, and the suite goes green on a namespace it knows is broken: $(brief "$SC_OUT")" ;;
    ok) if ! nsg_has_collision "$SC_COLLISION" "fail" "ctx-G1u"; then
            fail "G1u: a guard-owned channel fired, but no collision line naming fail at ctx-G1u reached stdout — the tally is internal to the guard, so a report nobody prints is a report nobody reads: $(brief "$SC_OUT")"
        elif ! printf '%s\n' "$SC_OUT" | grep -qE '^NSG-FAIL=[1-9][0-9]*$'; then
            fail "G1u: the collision was printed but the harness FAIL counter never moved ($(printf '%s\n' "$SC_OUT" | grep -E '^NSG-FAIL=' | head -1)) — the dispatcher's verdict is computed from that counter alone, so the suite still ends on \"All tests passed\": $(brief "$SC_OUT")"
        else
            pass "G1u: a no-op fail() swallows nothing — the guard prints its own collision line and bumps the counter the banner is computed from"
        fi ;;
esac

# G1un — the allow side of the same classifier (both-direction coverage). G1u alone is
# also satisfied by a guard that reports whenever it cannot read fail(); that guard would
# add a phantom FAIL to every clean run, so the identical no-op reporter is run here over
# a namespace where nothing was shadowed, and must produce no line and no counter move.
run_scenario G1un
case "$(nsg_verdict "$SC_OUT" G1un)" in
    absent|incomplete) fail "G1un: the scenario never reached NSG-DONE=G1un (rc=$SC_RC), so its silence says nothing about the guard: $(brief "$SC_OUT")" ;;
    ok) fail "G1un: nothing was shadowed and the no-op fail() predates the baseline, yet a guard-owned channel raised a verdict — G1u would then pass on a guard that reports the unreadability of fail() rather than a collision: $(brief "$SC_OUT")" ;;
    *) if [[ -n "$SC_COLLISION" ]]; then
           fail "G1un: nothing was shadowed, yet the guard printed a collision line: $(brief "$SC_COLLISION")"
       elif ! printf '%s\n' "$SC_OUT" | grep -qxF 'NSG-FAIL=0'; then
           fail "G1un: no collision line was printed, but the harness FAIL counter left 0 anyway — a clean run would go red with nothing to point at: $(brief "$SC_OUT")"
       else
           pass "G1un: an unreadable fail() is not itself a collision — no line printed, FAIL still 0"
       fi ;;
esac

# G1uc — the negative control for G1u's own classifier. G1u reads text, and a reader
# loose enough to accept a crash, a timeout or another mode's marker as "the guard fired"
# is exactly the false green G1u exists to close. These rows are synthetic outputs, so
# they grade nsg_verdict today, with no implementation in the picture.
nsg_synth() { local s; s="$(tbl_input_at "$1")"; nsg_verdict "$s" G1u; }
while IFS='|' read -r _name _in _want; do
    [[ -z "$_name" || "$_name" =~ ^[[:space:]]*# ]] && continue
    _name="${_name//[[:space:]]/}"
    _want="${_want//[[:space:]]/}"
    if [[ "$(nsg_synth "$_in")" == "$_want" ]]; then
        pass "G1uc/$_name"
    else
        fail "G1uc/$_name: want $_want, got $(nsg_synth "$_in") — the G1u reader grades this output wrongly"
    fi
done <<'TABLE'
absent-impl        | bash:~clg_assert_harness_intact:~command~not~found@NSG-RC=127@NSG-DONE=G1u | absent
crash-before-mark  | NSG-RC=1@bash:~line~9:~syntax~error~near~unexpected~token | incomplete
timeout-empty      |                                                          | incomplete
source-failure     | bash:~namespace-guard.sh:~No~such~file~or~directory       | incomplete
marker-other-mode  | NSG-RC=1@NSG-COUNT=1@NSG-LAST=pass@NSG-DONE=G1z           | incomplete
noop-guard         | NSG-RC=0@NSG-COUNT=unset@NSG-LAST=unset@NSG-DONE=G1u      | no-verdict
zero-tally         | NSG-RC=0@NSG-COUNT=0@NSG-LAST=@NSG-DONE=G1u              | no-verdict
rc-channel         | NSG-RC=1@NSG-COUNT=unset@NSG-LAST=unset@NSG-DONE=G1u      | ok
count-channel      | NSG-RC=0@NSG-COUNT=2@NSG-LAST=unset@NSG-DONE=G1u         | ok
last-channel       | NSG-RC=0@NSG-COUNT=unset@NSG-LAST=hx_probe~ctx-G1u@NSG-DONE=G1u | ok
TABLE

# G1z — the disappearance half. Every case above re-DEFINES a name; `unset -f pass` makes
# the name stop existing, and a guard that only diffs the bodies of names it can still see
# reads an unset pass() as "nothing to compare" and stays silent while the suite goes mute.
expect_report "G1z: unsetting the harness pass() is reported" \
    G1z "pass" "ctx-G1z"

echo ""
echo "=== G12: the post-cases counter re-pin ==="
# G12 — clg_rearm_counters, the one call the dispatcher makes before its final check
# point. PASS and FAIL are in direction A's retained set, yet the nine case files advance
# them by design, so the guard re-pins them there. G12f is that by-design advance: a
# re-pin that does not hold turns ordinary progress into a phantom collision on every run.
# G12b/G12p are the movement no test run produces — a case file resetting a counter to
# bury its own failures — which a blind re-pin would launder into progress. Both counters
# are covered because pinning one is not pinning both (CPR-ORTH with G1v/G1w).
expect_silent "G12f: counters that advanced across the case files are re-pinned, and the post-cases assert stays silent" G12f
expect_report "G12b: a FAIL counter that moved backward is reported before the re-pin" \
    G12b "FAIL" "post-cases"
expect_report "G12p: a PASS counter that moved backward is reported before the re-pin" \
    G12p "PASS" "post-cases"

# G12c — the corrupted counter. G12b/G12p only cover a counter that is still a
# number and merely smaller; the re-pin's backward test is `^[0-9]+$` on BOTH
# values, so an empty, negative or non-numeric counter fails to match, skips the
# whole comparison, and is re-pinned two lines later as the new baseline with
# nothing said. The dispatcher's banner then computes `[[ $FAIL -eq 0 ]]` over it:
# "" and "abc" both evaluate to 0, so the suite ends on "All tests passed" over a
# counter that was destroyed. Table-driven over both counters (CPR-ORTH with
# G1v/G1w) because pinning one is not pinning both.
for _cc in PASS FAIL; do
    for _cs in empty negative alpha; do
        expect_report "G12c/$_cc-$_cs: a $_cc counter that stopped being a count ($_cs) is reported before the re-pin" \
            "G12c-$_cc-$_cs" "$_cc" "post-cases"
    done
done
