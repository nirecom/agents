#!/usr/bin/env bash
# tests/bin-section-runner-wiring.sh
# Tests: tests/lib/section-runner.sh
# Tags: test-infrastructure, section-runner, wiring, meta-test, deliberate-breakage, scope:common, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Whether tests/run-all.sh itself surfaces a parent's non-zero exit. That is run-all's
#   contract, exercised by the real CI run; here the parent's own exit code is the boundary.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
#
# run-all.sh globs tests/*.sh at the TOP LEVEL only, so assertions under tests/<family>/
# reach CI exclusively via a parent's run_section call. If that path swallows a failure,
# whole families go silently green.
#
# Proof is by DELIBERATE BREAKAGE: a happy-path check passes against a swallowing bug too,
# so each case plants a fixture broken one specific way and asserts the PARENT exits
# non-zero. Fixtures are generated under a temp dir and driven through the REAL
# tests/lib/section-runner.sh, so no file in tests/ is touched.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$AGENTS_DIR/tests/lib/section-runner.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FIXTURES="$WORK/sections"; mkdir -p "$FIXTURES"

if [ ! -f "$RUNNER" ]; then
    fail "S0-section-runner-present" "tests/lib/section-runner.sh not found — the wiring under test does not exist"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
pass "S0-section-runner-present"

# --- fixture sections -----------------------------------------------------------------
# Each is a standalone program obeying (or deliberately violating) the section contract:
# exit 0 iff no failures, and print exactly one `Results: N passed, M failed` line.

cat > "$FIXTURES/good.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: fixture-good-1"
echo "PASS: fixture-good-2"
echo "Results: 2 passed, 0 failed"
exit 0
EOF

cat > "$FIXTURES/broken.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: fixture-broken-1"
echo "FAIL: fixture-broken-2 — deliberate breakage"
echo "Results: 1 passed, 1 failed"
exit 1
EOF

# Dies before it can report anything — a `set -e` abort, a missing dependency, a crash.
cat > "$FIXTURES/crashes.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: fixture-crash-1"
exit 3
EOF

# Reports failures but exits 0 — the two signals disagree.
cat > "$FIXTURES/lies-exit0.sh" <<'EOF'
#!/usr/bin/env bash
echo "Results: 0 passed, 2 failed"
exit 0
EOF

# Exits non-zero while claiming everything passed — a failure after the Results line.
cat > "$FIXTURES/lies-rc1.sh" <<'EOF'
#!/usr/bin/env bash
echo "Results: 3 passed, 0 failed"
exit 1
EOF

chmod +x "$FIXTURES"/*.sh

# --- parent driver --------------------------------------------------------------------
# Minimal stand-in for a top-level suite: the six things section-runner.sh requires of its
# caller, the real helper, and the same final exit convention.
make_parent() {  # <parent-path> <section-file>...
    local out="$1"; shift
    {
        echo '#!/usr/bin/env bash'
        echo 'set -u'
        echo 'PASS=0; FAIL=0'
        echo 'pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }'
        echo 'fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }'
        printf 'SECTION_DIR=%s\n' "'$FIXTURES'"
        printf 'RWT=%s\n' "'$RWT'"
        printf '. %s\n' "'$RUNNER'"
        local s
        for s in "$@"; do printf 'run_section %s 60\n' "'$s'"; done
        echo 'echo "Results: $PASS passed, $FAIL failed"'
        echo '[ "$FAIL" -eq 0 ] && exit 0 || exit 1'
    } > "$out"
}

# run_parent <name> <section-file>... → sets P_OUT, P_RC, P_PASS, P_FAIL
run_parent() {
    local name="$1"; shift
    local p="$WORK/parent-$name.sh"
    make_parent "$p" "$@"
    P_OUT="$(bash "$RWT" 90 bash "$p" 2>&1)"; P_RC=$?
    P_PASS="$(printf '%s\n' "$P_OUT" | sed -n 's/^Results: \([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed.*$/\1/p' | tail -n 1)"
    P_FAIL="$(printf '%s\n' "$P_OUT" | sed -n 's/^Results: \([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed.*$/\2/p' | tail -n 1)"
}

echo "=== S1: a healthy section is counted, and the parent stays green ==="
# The control: without it, a runner that always fails would satisfy every case below.
run_parent healthy good.sh
if [ "$P_RC" -eq 0 ]; then
    pass "S1-healthy-parent-exits-0"
else
    fail "S1-healthy-parent-exits-0" "want rc 0 (got: $P_RC); output: $P_OUT"
fi
if [ "${P_PASS:-0}" -eq 2 ] && [ "${P_FAIL:-1}" -eq 0 ]; then
    pass "S1b-healthy-section-counts-folded-into-the-parent-total"
else
    fail "S1b-healthy-section-counts-folded-into-the-parent-total" "want the parent total to be 2 passed / 0 failed (got: ${P_PASS:-?}/${P_FAIL:-?}) — a section whose assertions are not counted is not wired"
fi

echo ""
echo "=== S2: DELIBERATE BREAKAGE — a failing section must fail the parent ==="
run_parent broken broken.sh
if [ "$P_RC" -ne 0 ]; then
    pass "S2-broken-section-makes-the-parent-exit-nonzero"
else
    fail "S2-broken-section-makes-the-parent-exit-nonzero" "the parent exited 0 although its section reported a failure — every assertion under tests/<family>/ is unenforced; output: $P_OUT"
fi
if [ "${P_FAIL:-0}" -ge 1 ]; then
    pass "S2b-broken-section-failure-appears-in-the-parent-total"
else
    fail "S2b-broken-section-failure-appears-in-the-parent-total" "the parent's own Results line reports ${P_FAIL:-?} failures — the section's failure was dropped from the total; output: $P_OUT"
fi

echo ""
echo "=== S3: a section that dies before reporting is not silence ==="
# No Results line means no counters to add, and adding zero looks like a clean run unless
# the runner objects explicitly.
run_parent crashes crashes.sh
if [ "$P_RC" -ne 0 ]; then
    pass "S3-crashed-section-makes-the-parent-exit-nonzero"
else
    fail "S3-crashed-section-makes-the-parent-exit-nonzero" "a section that died mid-run left the parent green — 'the section stopped running' read as 'the section had nothing to say'; output: $P_OUT"
fi
if printf '%s' "$P_OUT" | grep -q 'section:crashes.sh'; then
    pass "S3b-crashed-section-is-named-in-the-failure"
else
    fail "S3b-crashed-section-is-named-in-the-failure" "the failure does not name the section that died, so the operator cannot locate it; output: $P_OUT"
fi

echo ""
echo "=== S4: the two signals must agree (exit code vs reported counters) ==="
run_parent lies-exit0 lies-exit0.sh
if [ "$P_RC" -ne 0 ]; then
    pass "S4-section-reporting-failures-while-exiting-0-still-fails-the-parent"
else
    fail "S4-section-reporting-failures-while-exiting-0-still-fails-the-parent" "a section reported 2 failures and exited 0, and the parent believed the exit code; output: $P_OUT"
fi

run_parent lies-rc1 lies-rc1.sh
if [ "$P_RC" -ne 0 ]; then
    pass "S4b-section-exiting-nonzero-while-reporting-0-failures-still-fails-the-parent"
else
    fail "S4b-section-exiting-nonzero-while-reporting-0-failures-still-fails-the-parent" "a section exited 1 while claiming 3 passed / 0 failed — a failure after its Results line was swallowed; output: $P_OUT"
fi

echo ""
echo "=== S5: a section the parent names but that does not exist ==="
# The rename/move accident: skipping it silently would delete coverage on the quiet.
run_parent missing does-not-exist.sh
if [ "$P_RC" -ne 0 ]; then
    pass "S5-missing-section-file-fails-the-parent"
else
    fail "S5-missing-section-file-fails-the-parent" "the parent referenced a section file that does not exist and still exited 0; output: $P_OUT"
fi

echo ""
echo "=== S6: one broken section among healthy ones is not diluted ==="
# A runner that ORs exit codes correctly but overwrites rather than accumulates counters
# passes every case above and fails only here.
run_parent mixed good.sh broken.sh good.sh
if [ "$P_RC" -ne 0 ]; then
    pass "S6-one-broken-section-among-healthy-ones-fails-the-parent"
else
    fail "S6-one-broken-section-among-healthy-ones-fails-the-parent" "the parent exited 0 with a failing section between two passing ones; output: $P_OUT"
fi
if [ "${P_PASS:-0}" -eq 5 ] && [ "${P_FAIL:-0}" -eq 1 ]; then
    pass "S6b-counts-accumulate-across-sections"
else
    fail "S6b-counts-accumulate-across-sections" "want 5 passed / 1 failed accumulated across three sections (got: ${P_PASS:-?}/${P_FAIL:-?}) — counters are overwritten, not accumulated; output: $P_OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
