# shellcheck shell=bash
# Tests: tests/bin-concern-ledger-reducer.sh, tests/bin-concern-ledger-reducer/namespace-guard.sh
# Tags: concern-ledger, test-harness, namespace-guard, wiring, robustness, TL2, scope:common
# A correct guard nobody calls protects nothing: G6 pins the dispatcher's six check
# points. G9/G10 pin what the guard must survive once it is called — an assert that
# runs before its own setup, and the same check point reached twelve times over.

echo ""
echo "=== G6: dispatcher wiring ==="
count_calls() { # count_calls <file> <token> — occurrences on non-comment lines
    grep -vE '^[[:space:]]*#' "$1" | grep -oF -- "$2" | wc -l | tr -d '[:space:]'
}
g6_a=$(count_calls "$DISPATCHER" "clg_assert_harness_intact")
g6_b=$(count_calls "$DISPATCHER" "clg_assert_library_intact")
if [[ "$g6_a" == "4" ]]; then
    pass "G6a: the dispatcher calls clg_assert_harness_intact at 4 points"
else
    fail "G6a: want 4 clg_assert_harness_intact calls in tests/bin-concern-ledger-reducer.sh, got $g6_a"
fi
if [[ "$g6_b" == "2" ]]; then
    pass "G6b: the dispatcher calls clg_assert_library_intact at 2 points"
else
    fail "G6b: want 2 clg_assert_library_intact calls in tests/bin-concern-ledger-reducer.sh, got $g6_b"
fi
if grep -vE '^[[:space:]]*#' "$DISPATCHER" | grep -Fq 'namespace-guard.sh'; then
    pass "G6c: the dispatcher sources namespace-guard.sh"
else
    fail "G6c: tests/bin-concern-ledger-reducer.sh never sources namespace-guard.sh"
fi

echo ""
echo "=== G9/G10: robustness across the dispatcher's six check points ==="
# G9 — out-of-order use. The dispatcher places asserts at six points and a later edit
# can move one above the setup calls. Whether the guard reports that is its choice;
# taking the whole suite down with a crash is not, so only rc and silence are pinned.
run_scenario G9
if [[ -n "$SC_OUT" ]]; then
    fail "G9: asserting before clg_snapshot_before wrote to stdout/stderr: $(brief "$SC_OUT")"
elif [[ "$SC_RC" != "0" ]]; then
    fail "G9: asserting before clg_snapshot_before exited $SC_RC — an unconfigured guard must degrade, not kill the suite"
else
    pass "G9: asserting before the snapshot neither crashes nor writes output"
fi

# G10 — idempotency. Six clean check points in one process must stay silent; a guard
# that re-snapshots inside an assert, or leaks a global of its own, drifts and starts
# reporting phantom collisions at the later call sites.
expect_silent "G10: twelve consecutive check points on an untouched namespace stay silent" G10

echo ""
echo "=== G15: the guard armed inside the REAL dispatcher, not a stand-in ==="
# G15 — G6 only greps source text; nothing runs tests/bin-concern-ledger-reducer.sh
# itself, so an unarmed CLG_USABLE (e.g. a CLG_DIR mkdir race) would leave every real
# check point a silent no-op with G6a/G6b still green.
# The real, UNMODIFIED dispatcher is sourced (never edited/copied) into an isolated
# subshell (its pass/fail/PASS/FAIL never touch this suite's). `$0` is unchanged by
# `.`, and this file and the dispatcher are tests/ siblings, so AGENTS_ROOT still
# resolves correctly. `exit` is shadowed just long enough to capture the verdict
# instead of tearing the subshell down, so a genuine collision can be injected after.
G15_OUT="$(
    G15_EXITED=0
    exit() {
        [ "$G15_EXITED" -eq 1 ] && return 0
        G15_EXITED=1
        G15_RC="${1:-0}"
        return 0
    }
    # CWD drifts across the earlier case files in this suite (several cd into their own
    # mktemp fixture dirs), and the real dispatcher re-derives AGENTS_ROOT from a
    # dirname($0)-relative lookup that only resolves from the ORIGINAL invocation
    # directory — so it is restored here before sourcing, in this subshell only.
    cd "$AGENTS_ROOT" || exit 1
    # shellcheck source=/dev/null
    . "$DISPATCHER" >/dev/null 2>&1
    printf 'REAL-EXIT-RC=%s\n' "${G15_RC:-unset}"
    printf 'REAL-USABLE=%s\n' "${CLG_USABLE:-unset}"
    printf 'REAL-LOADED=%s\n' "${CLG_LIB_LOADED:-unset}"
    printf 'REAL-FAIL=%s\n' "${FAIL:-unset}"
    # A GENUINE collision on run_cli — one of G6a's 4 watched real call sites — in the
    # real harness's own post-run shell. Counters reset first so only this counts.
    run_cli() { printf 'clobbered\n'; }
    CLG_REPORT_COUNT=0
    CLG_LAST_REPORT=""
    clg_assert_harness_intact "ctx-G15-real"
    printf 'REAL-REPORT-COUNT=%s\n' "${CLG_REPORT_COUNT:-unset}"
    printf 'REAL-LAST-REPORT=%s\n' "${CLG_LAST_REPORT:-unset}"
)"
G15_EXIT_RC="$(printf '%s\n' "$G15_OUT" | grep -oE '^REAL-EXIT-RC=.*' | cut -d= -f2-)"
G15_USABLE="$(printf '%s\n' "$G15_OUT" | grep -oE '^REAL-USABLE=.*' | cut -d= -f2-)"
G15_LOADED="$(printf '%s\n' "$G15_OUT" | grep -oE '^REAL-LOADED=.*' | cut -d= -f2-)"
G15_REPORTN="$(printf '%s\n' "$G15_OUT" | grep -oE '^REAL-REPORT-COUNT=.*' | cut -d= -f2-)"
G15_LAST="$(printf '%s\n' "$G15_OUT" | grep -oE '^REAL-LAST-REPORT=.*' | cut -d= -f2-)"

if [[ "$G15_EXIT_RC" != "0" ]]; then
    fail "G15-setup: the real dispatcher itself did not exit 0 on an unmodified run (rc=$G15_EXIT_RC) — the collision probe below would prove nothing: $(brief "$G15_OUT")"
else
    pass "G15-setup: the unmodified real dispatcher run completed cleanly (rc=0), so the collision probe runs against a genuinely passing baseline"
fi

if [[ "$G15_LOADED" == "1" && "$G15_USABLE" == "1" ]]; then
    pass "G15-armed: CLG_USABLE is 1 inside the REAL dispatcher's own process after a full real run (CLG_LIB_LOADED=$G15_LOADED)"
else
    fail "G15-armed: want CLG_LIB_LOADED=1 and CLG_USABLE=1 inside the real dispatcher, got LOADED=$G15_LOADED USABLE=$G15_USABLE — every real check point is a silent no-op when this is unset"
fi

# clg_report's own FAIL bump is itself a harness-variable change, so a genuine run_cli
# collision is routinely followed by a second, self-inflicted "FAIL changed" collision
# (the same pattern documented for expect_report above) — at least one report naming
# run_cli, not an exact count of one, is what proves the guard fired for real.
if [[ "${G15_REPORTN:-0}" -ge 1 ]] && printf '%s\n' "$G15_OUT" | grep -qE '^FAIL: namespace collision at ctx-G15-real: run_cli '; then
    pass "G15-fires: the REAL dispatcher's own guard reports a genuine run_cli collision after the real run — the guard is wired AND live, not just statically referenced"
else
    fail "G15-fires: want at least one collision naming run_cli at ctx-G15-real, got REPORT-COUNT=$G15_REPORTN LAST-REPORT=$(printf '%q' "$G15_LAST") — output: $(brief "$G15_OUT")"
fi
