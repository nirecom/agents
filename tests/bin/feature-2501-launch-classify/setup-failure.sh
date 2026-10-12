# tests/bin/feature-2501-launch-classify/setup-failure.sh
# Tests: bin/lib/run-all-launch.sh
# Tags: TL2, bin, run-all, launch, setup-failure, unsupported, scope:issue-specific
# shellcheck shell=bash
# run_all_exec's own setup failures (launcher libraries missing, an unreadable table, no temporary
# result dir) are the runner's failure: rc 2 with state FAIL, so tests/run-all.sh exits non-zero.
# UNSUPPORTED / 78 stays reserved for a file whose language is not run.
# Sourced by the dispatcher (after exec.sh, which builds $CO and m-env.sh).

echo ""
echo "=== run_all_exec: setup failures ==="

SF_WANT="rc=2 state=FAIL execrc=2 launched=0"

# sf_not_run <tag> — the test body must never have started.
sf_not_run() {
  if grep -q 'rdir=' "$TMPBASE/rae-$1.out" 2>/dev/null; then
    fail "$1: the test was launched anyway"
  else
    pass "$1: the test was not launched"
  fi
}

COB="$TMPBASE/co-broken"
fx_co "$COB" || fail "fixture checkout (broken table)" "fx_co failed"
printf '{ "schema": 1, "entries": [ not json\n' >"$COB/hooks/lib/test-language-registry.json"
cp "$CO/tests/bin/m-env.sh" "$COB/tests/bin/m-env.sh"

case_begin "unreadable-table-is-fail-not-unsupported" "bin/lib/run-all-launch.sh"
mkdir -p "$TMPBASE/res-sf-table"
rae sf-table "$COB" "$COB/tests/bin/m-env.sh" "$TMPBASE/res-sf-table"
assert_eq "unreadable table: $(rae_full sf-table)" "unreadable table: $SF_WANT"
sf_not_run sf-table
case_end

# A launcher with none of its sibling libraries beside it.
LONE="$TMPBASE/lone"
mkdir -p "$LONE/bin/lib" "$LONE/tests/bin"
cp "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-launch.sh" "$LONE/bin/lib/run-all-launch.sh"
cp "$CO/tests/bin/m-env.sh" "$LONE/tests/bin/m-env.sh"

case_begin "missing-launcher-libs-is-fail-not-unsupported" "bin/lib/run-all-launch.sh"
mkdir -p "$TMPBASE/res-sf-lone"
rae sf-lone "$LONE" "$LONE/tests/bin/m-env.sh" "$TMPBASE/res-sf-lone"
assert_eq "no launcher libs: $(rae_full sf-lone)" "no launcher libs: $SF_WANT"
assert_eq "no launcher libs: diagnostic lines=$(grep -c 'launcher libraries not found' "$TMPBASE/rae-sf-lone.err2" 2>/dev/null || true)" \
  "no launcher libs: diagnostic lines=1"
sf_not_run sf-lone
case_end

# A PATH-shadowing mktemp that refuses only the launcher's result-dir template, so every other
# mktemp (the harness, timed_exec) still works and the failure no longer depends on the host.
SF_STUB="$TMPBASE/sf-mktemp-bin"
mkdir -p "$SF_STUB"
cat >"$SF_STUB/mktemp" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *"/run-all-result."*)
    printf '%s\n' "$*" >>"$SF_MKTEMP_LOG"
    exit 1
    ;;
esac
exec "$SF_REAL_MKTEMP" "$@"
EOF
chmod +x "$SF_STUB/mktemp"

case_begin "no-temp-result-dir-is-fail-not-unsupported" "bin/lib/run-all-launch.sh"
# No result dir argument and a mktemp -d that fails: the launcher's own setup failure.
SF_REAL_MKTEMP="$(command -v mktemp)"
(
  export SF_REAL_MKTEMP SF_MKTEMP_LOG="$TMPBASE/sf-mktemp.log" PATH="$SF_STUB:$PATH"
  rae sf-mktemp "$CO" "$CO/tests/bin/m-env.sh"
)
assert_eq "no temp result dir: refused mktemp calls=$(grep -c 'run-all-result\.' "$TMPBASE/sf-mktemp.log" 2>/dev/null || true)" \
  "no temp result dir: refused mktemp calls=1"
assert_eq "no temp result dir: $(rae_full sf-mktemp)" "no temp result dir: $SF_WANT"
sf_not_run sf-mktemp
case_end

printf '%s\n' 'echo should-not-run' >"$CO/tests/bin/t.nolang2501"
printf '%s\n' 'echo should-not-run' >"$CO/tests/bin/x.spec.nolang2501"

case_begin "language-not-run-stays-unsupported" "bin/lib/run-all-launch.sh"
for sf_name in t.nolang2501 x.spec.nolang2501; do
  mkdir -p "$TMPBASE/res-sf-$sf_name"
  rae "sf-$sf_name" "$CO" "$CO/tests/bin/$sf_name" "$TMPBASE/res-sf-$sf_name"
  assert_eq "$sf_name: $(rae_full "sf-$sf_name")" "$sf_name: rc=78 state=UNSUPPORTED execrc=78 launched=0"
  assert_eq "$sf_name: UNSUPPORTED lines=$(grep -c "^UNSUPPORTED: .*$sf_name (language: .*; not run)\$" "$TMPBASE/rae-sf-$sf_name.out" 2>/dev/null || true)" \
    "$sf_name: UNSUPPORTED lines=1"
done
case_end

# ra_e2e <tag> [<launcher>] — the checkout's tests/run-all.sh on m-env.sh alone; its exit code goes
# to RA_RC and its report to $TMPBASE/ra-<tag>.out (kept in a file: the lines are report-shaped).
cp "$SCRIPT_CHECKOUT_ROOT/tests/run-all.sh" "$CO/tests/run-all.sh"
ra_e2e() {
  RA_RC=0
  (
    unset RUN_ALL_REGISTRY_LIB RUN_ALL_REPORT_LIB RUN_ALL_DURATIONS_LIB RUN_ALL_LANES_LIB RUN_ALL_LAUNCH_LIB
    unset TESTS_DIR RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_REAP RUN_ALL_WAITN_PROBE
    # A parallelism library that is not there: no cache dir, no host lanes, no duration ledger.
    export RUN_ALL_PARALLELISM_LIB="$TMPBASE/no-such-lib.sh" RUN_ALL_PROGRESS=off
    if [ -n "${2-}" ]; then export RUN_ALL_LAUNCH_LIB="$2"; fi
    run_with_timeout 120 bash "$CO/tests/run-all.sh" -j 1 "$CO/tests/bin/m-env.sh" \
      >"$TMPBASE/ra-$1.out" 2>"$TMPBASE/ra-$1.err" </dev/null
  ) || RA_RC=$?
}
# ra_lines <tag> <ERE> — how many report lines match.
ra_lines() { grep -c -E "$2" "$TMPBASE/ra-$1.out" 2>/dev/null || true; }

case_begin "run-all-exits-nonzero-on-a-launcher-setup-failure" "bin/lib/run-all-launch.sh"
ra_e2e ok
assert_eq "healthy launcher: exit=$RA_RC pass lines=$(ra_lines ok '^PASS: .*/m-env\.sh$')" "healthy launcher: exit=0 pass lines=1"
ra_e2e lone "$LONE/bin/lib/run-all-launch.sh"
assert_eq "launcher without libs: exit=$RA_RC" "launcher without libs: exit=1"
assert_eq "launcher without libs: file-level lines=$(ra_lines lone '^FAIL: .*/m-env\.sh \(exit 2\)$')" "launcher without libs: file-level lines=1"
assert_eq "launcher without libs: pass lines=$(ra_lines lone '^PASS: ')" "launcher without libs: pass lines=0"
case_end
