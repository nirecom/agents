#!/bin/bash
# tests/feature-2099-complexity-stage-routing/tl3-gate-cases.sh
# Tests: tests/TL3-complexity-stage-routing-live-judge.sh, bin/select-tests.sh, tests/feature-2099-complexity-stage-routing.sh
# Tags: complexity, routing, tl3, skip-gate, test-infra, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# The GATE-OFF branch of the RUN_TL3-gated cases, covered deterministically here
# (rules/test/claude-e2e.md: both branches of a config-gated behaviour need
# coverage). Nothing below spends a token: it drives the gate, never the judge.

D2099G_LANE="$AGENTS_DIR/tests/TL3-complexity-stage-routing-live-judge.sh"

# GATE-1: with RUN_TL3 off the lane must SKIP the runner's way — exit 77, which
# tests/run-all.sh counts as SKIP. Exit 0 would be the false green: a lane that
# reports success without having run a single live case.
d2099g_lane_skips_when_off() {
    local rc=0 out
    if [ ! -f "$D2099G_LANE" ]; then
        fail "GATE-1 the RUN_TL3-ON lane is missing at $D2099G_LANE — the #2099 live cases have no CI hook"
        return
    fi
    out=$(RUN_TL3=off run_with_timeout bash "$D2099G_LANE" 2>&1) || rc=$?
    assert_eq "GATE-1 the lane exits 77 (the runner's SKIP code) when RUN_TL3 is off" "77" "$rc"
    assert_not_contains "GATE-2 ... without having run the suite behind the gate" "=== Results ===" "$out"
}

# GATE-3: being selectable is what makes the lane more than opt-in. bin/select-tests.sh
# appends the expensive tier by FILENAME GLOB at tests/ depth 1 — the same
# expression is re-run here, so a rename that drops the lane out of the tier fails.
d2099g_lane_is_selected() {
    local found selector
    found=$(find "$AGENTS_DIR/tests" -maxdepth 1 -name "TL3-*.sh" | grep -c "TL3-complexity-stage-routing-live-judge.sh")
    assert_eq "GATE-3 the lane matches the TL3 tier's own selection expression" "1" "$found"
    selector=$(grep -c 'TL3-\*\.sh' "$AGENTS_DIR/bin/select-tests.sh" 2>/dev/null || echo 0)
    if [ "$selector" -ge 1 ]; then
        pass "GATE-4 bin/select-tests.sh still selects the tier by that expression"
    else
        fail "GATE-4 bin/select-tests.sh no longer selects by the 'TL3-*.sh' glob — the lane's wiring assumption is stale"
    fi
}

# GATE-5..: the gate's own two branches, on the real case files. A harness with
# no-op assertion helpers sources each live case file against an AGENTS_DIR that
# carries no gate binary, so the first gate is closed by construction. The
# gated_skip implementation is lifted VERBATIM out of the dispatcher rather than
# restated, so this measures the shipped helper.
d2099g_harness() {
    local case_file="$1" require="$2" h fake
    h="$TMPDIR_BASE/gate-harness-$$.sh"
    fake="$TMPDIR_BASE/gate-fake-agents"
    mkdir -p "$fake"
    {
        printf '#!/bin/bash\n'
        printf 'ERRORS=0\n'
        printf 'fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }\n'
        printf 'pass() { echo "PASS: $1"; }\n'
        printf 'skip() { echo "SKIP: $1"; }\n'
        sed -n '/^gated_skip() {/,/^}/p' "$AGENTS_DIR/tests/feature-2099-complexity-stage-routing.sh"
        # Everything else the sourced file touches before its gate, neutralized.
        printf 'assert_eq() { :; }\nassert_contains() { :; }\nassert_not_contains() { :; }\n'
        printf 'run_with_timeout() { :; }\nto_node_path() { echo "$1"; }\nnew_session() { echo gate; }\n'
        printf 'AGENTS_DIR="%s"\nRUBRIC="/dev/null"\nTMPDIR_BASE="%s"\n' "$fake" "$TMPDIR_BASE"
        printf 'BIN_RECORD="/dev/null"\nBIN_READ="/dev/null"\nBIN_DERIVE="/dev/null"\nCR_MOD_N="/dev/null"\n'
        printf '. "%s"\n' "$case_file"
    } > "$h"
    D2099_REQUIRE_LIVE="$require" run_with_timeout bash "$h" 2>&1
}

d2099g_gate_branches() {
    local out lifted
    lifted=$(sed -n '/^gated_skip() {/,/^}/p' "$AGENTS_DIR/tests/feature-2099-complexity-stage-routing.sh" | grep -c 'D2099_REQUIRE_LIVE')
    if [ "$lifted" -lt 1 ]; then
        fail "GATE-5 the dispatcher's gated_skip could not be lifted (or no longer reads D2099_REQUIRE_LIVE) — the branches below would test a stub"
        return
    fi
    pass "GATE-5 the dispatcher's gated_skip is liftable and reads D2099_REQUIRE_LIVE"

    # (a) ordinary run, gate closed: a SKIP, and never a silent pass.
    out=$(d2099g_harness "$CASE_DIR/judge-threshold-live-cases.sh" 0)
    assert_contains "GATE-6 JT-1 reports SKIP when its gate is closed on an ordinary run" "SKIP: JT-1" "$out"
    assert_not_contains "GATE-6b ... and does not report a PASS it never earned" "PASS: JT-1 " "$out"
    out=$(d2099g_harness "$CASE_DIR/prompt-injection-cases.sh" 0)
    assert_contains "GATE-7 PI-5 reports SKIP when its gate is closed on an ordinary run" "SKIP: PI-5" "$out"
    assert_not_contains "GATE-7b ... and does not report a PASS it never earned" "PASS: PI-5 " "$out"

    # (b) the required-live lane: the same closed gate must FAIL, not skip.
    out=$(d2099g_harness "$CASE_DIR/judge-threshold-live-cases.sh" 1)
    assert_contains "GATE-8 JT-1 FAILS instead of skipping when the required-live lane finds its gate closed" "FAIL: JT-1" "$out"
    assert_not_contains "GATE-8b ... so the lane can never report a silent skip" "SKIP: JT-1" "$out"
    out=$(d2099g_harness "$CASE_DIR/prompt-injection-cases.sh" 1)
    assert_contains "GATE-9 PI-5 FAILS instead of skipping when the required-live lane finds its gate closed" "FAIL: PI-5" "$out"
    assert_not_contains "GATE-9b ... so the lane can never report a silent skip" "SKIP: PI-5" "$out"
}

# --- GATE-10..: the gate's ON branch -----------------------------------------
# GATE-1 only pins RUN_TL3=off. A gate written `!= "on"` where `== "on"` was meant
# still exits 77 there, so the lane would skip forever and nobody would notice.
# This builds a throwaway AGENTS_DIR beside the real lane script — a config stub
# that answers "not off", a `claude` stub on PATH, and a SUITE stub that records
# having been invoked — so the ON branch is observable without a token or a
# network call. `$0`'s dirname is what the lane resolves AGENTS_DIR from, so the
# lane is copied into the fake tree rather than pointed at it.
d2099g_build_fake_lane() {
    local fake="$1" ids="$2"
    mkdir -p "$fake/bin" "$fake/tests" "$fake/path"
    cp "$D2099G_LANE" "$fake/tests/$(basename "$D2099G_LANE")"
    {
        printf '#!/bin/bash\n'
        printf '# --is-off RUN_TL3 off: exit 0 means OFF. This stub answers NOT off.\n'
        printf 'exit 1\n'
    } > "$fake/bin/get-config-var"
    printf '#!/bin/bash\nexit 0\n' > "$fake/path/claude"
    {
        printf '#!/bin/bash\n'
        # A marker file, not stdout: the lane captures the suite's output into a
        # temp file it deletes, so anything printed here is unobservable.
        printf 'printf "%%s" "${D2099_REQUIRE_LIVE:-unset}" > "%s/suite-was-invoked"\n' "$fake"
        printf 'for id in %s; do printf "PASS: $id the stub suite ran this case\\n"; done\n' "$ids"
        printf 'echo "=== Results ==="\nexit 0\n'
    } > "$fake/tests/feature-2099-complexity-stage-routing.sh"
    chmod +x "$fake/bin/get-config-var" "$fake/path/claude" \
        "$fake/tests/feature-2099-complexity-stage-routing.sh" 2>/dev/null || true
}

d2099g_lane_runs_when_on() {
    local fake out rc=0
    local all="PI-5 JT-1 JT-2 JT-3 JT-4 JT-5 JT-6 JT-7 JT-8 JT-9 JT-10 JT-11 JT-12 JT-13 JT-14 E2E-1 E2E-2 E2E-3 E2E-4"
    if [ ! -f "$D2099G_LANE" ]; then
        fail "GATE-10 the RUN_TL3-ON lane is missing at $D2099G_LANE — its ON branch cannot be exercised"
        return
    fi
    fake="$TMPDIR_BASE/gate-on-fake"
    rm -rf "$fake"
    d2099g_build_fake_lane "$fake" "$all"
    out=$(PATH="$fake/path:$PATH" run_with_timeout bash "$fake/tests/$(basename "$D2099G_LANE")" 2>&1) || rc=$?
    assert_eq "GATE-10 with the config stub answering 'not off', the lane runs to completion instead of exiting 77" \
        "0" "$rc"
    if [ -f "$fake/suite-was-invoked" ]; then
        pass "GATE-11 ... having actually invoked the suite behind the gate"
    else
        fail "GATE-11 ... but the suite behind the gate was NEVER invoked — the lane passed its gate and ran nothing"
    fi
    assert_eq "GATE-12 ... and drove it in required-live mode" \
        "1" "$(cat "$fake/suite-was-invoked" 2>/dev/null)"
    assert_contains "GATE-13 ... reporting the live ids it is accountable for" \
        "PASS: JT-10 executed in the RUN_TL3-ON lane" "$out"

    # Teeth: a suite that stops emitting a mandatory live id must break the lane,
    # otherwise GATE-13 would pass for any suite that merely exits 0.
    rc=0
    fake="$TMPDIR_BASE/gate-on-fake-missing"
    rm -rf "$fake"
    d2099g_build_fake_lane "$fake" "${all/ JT-10/}"
    out=$(PATH="$fake/path:$PATH" run_with_timeout bash "$fake/tests/$(basename "$D2099G_LANE")" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "GATE-14 the lane FAILS when the suite stops emitting a mandatory live id (JT-10)"
    else
        fail "GATE-14 the lane exited 0 though JT-10 produced no PASS/FAIL line — its coverage accounting has no teeth"
    fi
    assert_contains "GATE-14a ... naming the id that vanished" "JT-10 produced no PASS/FAIL line" "$out"
}

d2099g_lane_skips_when_off
d2099g_lane_is_selected
d2099g_gate_branches
d2099g_lane_runs_when_on
