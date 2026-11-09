#!/bin/bash
# tests/tests/feature-689-run-all-all-flag/unsupported-cases.sh — sourced by the dispatcher.
# Tests: tests/run-all.sh
# Tags: bin, tests, scope:issue-specific
# C8: a file the launcher declines against a launched script that itself exits 78.

# C8 (#2500): a file the launcher declines (rc 78 with RUN_ALL_EXEC_LAUNCHED=0 — here a
# suite-unit file with no suite root) prints UNSUPPORTED and moves no tally, contract or
# exit; a launched script that itself exits 78 is an ordinary FAIL. The pre-filter
# UNSUPPORTED path (recognized-only / unmatched) is U1-U5 in feature-2007-run-all-ps1-dispatch.sh.
# The runner and launcher load a fixture checkout's table, never the repo's.
test_C8_not_launched_unsupported_not_counted() {
    local co="$TMPROOT/co-unsup" lone x78 okt out rc ctl_out ctl_rc ok=1 f decoy
    mkdir -p "$co/bin" "$co/hooks/lib" "$co/tests/lone" "$co/tests/bin" "$co/tests/lib"
    cp -R "$SCRIPT_CHECKOUT_ROOT/bin/lib" "$co/bin/lib"
    cp "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" "$co/bin/"
    # The fixture launcher refuses to run without its own root decoy: the library, its builder
    # and the file the builder reads the retired names from. The builder lists the checkout's
    # tracked files, so the checkout is a git repo; a run with no inherited decoy builds in TMPROOT.
    for f in tests/lib/root-decoy.sh tests/lib/root-decoy-build.js tests/bin/feature-2561-root-names-residue.sh; do
        cp "$SCRIPT_CHECKOUT_ROOT/$f" "$co/$f"
    done
    git init -q "$co" >/dev/null 2>&1
    git -C "$co" config core.hooksPath /dev/null
    decoy="${ROOT_DECOY_DIR:-$TMPROOT/co-unsup-decoy}"
    install_test_language_registry "$co" "$SCRIPT_CHECKOUT_ROOT"
    cp "$SCRIPT_CHECKOUT_ROOT/tests/bin/test-language-registry/fixtures/fake-suite.json" "$co/hooks/lib/test-language-registry.json"
    lone="$co/tests/lone/c.fakesuite"; x78="$co/tests/bin/x78.sh"; okt="$co/tests/bin/ok.sh"
    printf '# t\n' > "$lone"
    printf '#!/bin/bash\nexit 78\n' > "$x78"
    printf '#!/bin/bash\nexit 0\n' > "$okt"
    out="$(ROOT_DECOY_DIR="$decoy" RUN_ALL_REGISTRY_LIB="$co/bin/lib/test-language-registry.sh" RUN_ALL_LAUNCH_LIB="$co/bin/lib/run-all-launch.sh" \
        run_with_timeout 120 bash "$RUN_ALL" "$lone" "$x78" "$okt" 2>/dev/null)"
    rc=$?
    ctl_out="$(ROOT_DECOY_DIR="$decoy" RUN_ALL_REGISTRY_LIB="$co/bin/lib/test-language-registry.sh" RUN_ALL_LAUNCH_LIB="$co/bin/lib/run-all-launch.sh" \
        run_with_timeout 120 bash "$RUN_ALL" "$lone" "$okt" 2>/dev/null)"
    ctl_rc=$?
    [ "$(count_lines '^UNSUPPORTED: ' "$out")" = "1" ] || ok=0
    has_fixed "UNSUPPORTED: $lone (language: fake-suite; no suite root fake.root)" "$out" || ok=0
    [ "$(count_lines '^(PASS|FAIL|SKIP): .*c\.fakesuite' "$out")" = "0" ] || ok=0
    has_fixed "FAIL: $x78 (exit 78)" "$out" || ok=0
    has_fixed "PASS: $okt" "$out" || ok=0
    has_line '^RUN_CONTRACT: PASS=1 FAIL=1 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0$' "$out" || ok=0
    [ "$rc" = "1" ] || ok=0
    has_fixed "UNSUPPORTED: $lone (language: fake-suite; no suite root fake.root)" "$ctl_out" || ok=0
    has_line '^RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0$' "$ctl_out" || ok=0
    [ "$ctl_rc" = "0" ] || ok=0
    if [ "$ok" = "1" ]; then
        pass "C8_not_launched_unsupported_not_counted: declined file is UNSUPPORTED and uncounted; launched exit 78 is FAIL (rc=$rc, control rc=$ctl_rc)"
    else
        fail "C8_not_launched_unsupported_not_counted: rc=$rc control-rc=$ctl_rc (want UNSUPPORTED line, FAIL (exit 78), PASS=1 FAIL=1 EXECUTED=2 rc=1; control PASS=1 FAIL=0 EXECUTED=1 rc=0)"
        diag "$out"
        diag "$ctl_out"
    fi
}
