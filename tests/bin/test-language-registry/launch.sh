# Launch through the table: suite-unit languages (fixture fake-suite), the
# not-launched markers, the base checkout's own table under rtb_exec_one, and the
# retire unit of trp_unit_of. Sourced by the dispatcher.

echo ""
echo "=== launch ==="

FX_SUITE="$TMPBASE/co-fake-suite"
fx_checkout "$FX_SUITE" "$FIXTURES/fake-suite.json"
SU="$FX_SUITE/tests/suites"
mkdir -p "$SU/s1" "$SU/s2" "$SU/lone"
: >"$SU/s1/fake.root"
: >"$SU/s2/fake.root"
for f in s1/a.fakesuite s1/b.fakesuite s2/a.fakesuite s2/b.fakesuite lone/c.fakesuite; do echo "# t" >"$SU/$f"; done
printf '%s\n' 'echo plain-bash' >"$SU/x.sh"
printf '%s\n' 'echo never' >"$SU/u.zzz"

# lch <checkout> <test> <tag> — run_all_exec of that checkout; prints "rc=N launched=V"
# and leaves the output in $TMPBASE/lch-<tag>.out.
lch() {
  tlr_bash "$1" '. "$1/bin/lib/run-all-launch.sh" || exit 95
run_all_exec "$2" "$3" "$4"; printf "rc=%s launched=%s" "$?" "${RUN_ALL_EXEC_LAUNCHED:-unset}"' \
    "$1" "$2" "$TMPBASE/lch-$3.out" "$TMPBASE/lch-$3.err"
}
lines_of() { if [ -f "$1" ]; then tr '\n' ' ' <"$1"; else printf '<absent>'; fi; }

case_begin "suite-dedupe" "bin/lib/test-language-registry.sh"
# One representative per (id, suite root), first by name; others pass through in order.
printf '%s\n' "$SU/s1/b.fakesuite" "$SU/s1/a.fakesuite" "$SU/x.sh" "$SU/s2/a.fakesuite" \
  "$SU/s2/b.fakesuite" "$SU/lone/c.fakesuite" >"$TMPBASE/suite-list"
got="$(tlr_bash "$FX_SUITE" 'tlr_load || exit 96; tlr_dedupe_suites <"$1"' "$TMPBASE/suite-list" | sed "s#^$SU/##" | tr '\n' ' ')"
assert_eq "$got" "s1/a.fakesuite x.sh s2/a.fakesuite lone/c.fakesuite "
got="$(tlr_bash "$FX_SUITE" 'tlr_load || exit 96; tlr_suite_root fake-suite "$1"' "$SU/s1/b.fakesuite")"
assert_eq "suite root of s1/b: ${got#"$SU/"}" "suite root of s1/b: s1"
case_end

case_begin "suite-launch-prepare-then-command" "bin/lib/run-all-launch.sh"
for s in s1 s2; do
  got="$(lch "$FX_SUITE" "$SU/$s/a.fakesuite" "$s")"
  assert_eq "$s: $got" "$s: rc=0 launched=1"
  assert_eq "$s prep.log: $(lines_of "$SU/$s/prep.log")" "$s prep.log: prep "
  assert_eq "$s run.log: $(lines_of "$SU/$s/run.log")" "$s run.log: run-after-prep "
done
case_end

case_begin "suite-dedupe-through-run-all" "tests/run-all.sh"
# Every file of two suites named to the real runner (b before a): one prepare and one command
# per suite root, and one result line per suite naming its first file by name.
FX_RR="$TMPBASE/co-fake-suite-run-all"
fx_checkout "$FX_RR" "$FIXTURES/fake-suite.json"
cp "$SCRIPT_CHECKOUT_ROOT/tests/run-all.sh" "$FX_RR/tests/run-all.sh"
RR="$FX_RR/tests/suites"
for s in s1 s2; do
  mkdir -p "$RR/$s"
  : >"$RR/$s/fake.root"
  for f in b a; do echo "# t" >"$RR/$s/$f.fakesuite"; done
done
rr_rc=0
# TEST_LANES=off: the nested runner must not queue for a host lane the outer run already holds.
run_with_timeout 180 env TEST_LANES=off TESTS_DIR="$FX_RR/tests" bash "$FX_RR/tests/run-all.sh" \
  "$RR/s1/b.fakesuite" "$RR/s1/a.fakesuite" "$RR/s2/b.fakesuite" "$RR/s2/a.fakesuite" \
  >"$TMPBASE/rr.out" 2>"$TMPBASE/rr.err" || rr_rc=$?
assert_eq "run-all: rc=$rr_rc" "run-all: rc=0"
for s in s1 s2; do
  assert_eq "run-all $s prep.log: $(lines_of "$RR/$s/prep.log")" "run-all $s prep.log: prep "
  assert_eq "run-all $s run.log: $(lines_of "$RR/$s/run.log")" "run-all $s run.log: run-after-prep "
done
got="$(grep -E '^(PASS|FAIL|SKIP): ' "$TMPBASE/rr.out" | sed "s#^\([A-Z]*\): $RR/#\1 #" | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "run-all result lines: $got" "run-all result lines: PASS s1/a.fakesuite PASS s2/a.fakesuite "
assert_eq "run-all contract: $(grep -E '^RUN_CONTRACT: ' "$TMPBASE/rr.out")" "run-all contract: RUN_CONTRACT: PASS=2 FAIL=0 SKIP=0 EXECUTED=2"
case_end

case_begin "suite-without-root-is-78" "bin/lib/run-all-launch.sh"
got="$(lch "$FX_SUITE" "$SU/lone/c.fakesuite" lone)"
assert_eq "lone: $got" "lone: rc=78 launched=0"
has_line "lone: UNSUPPORTED line" "$(cat "$TMPBASE/lch-lone.out" 2>/dev/null)" "UNSUPPORTED: $SU/lone/c.fakesuite (language: fake-suite; no suite root fake.root)"
case_end

case_begin "unsupported-file-is-78" "bin/lib/run-all-launch.sh"
got="$(lch "$FX_SUITE" "$SU/u.zzz" unknown)"
assert_eq "unknown: $got" "unknown: rc=78 launched=0"
has_line "unknown: UNSUPPORTED line" "$(cat "$TMPBASE/lch-unknown.out" 2>/dev/null)" "UNSUPPORTED: $SU/u.zzz (language: unknown; not run)"
mkdir -p "$TMPBASE/js"
echo 'process.exit(0)' >"$TMPBASE/js/x.js"
got="$(lch "$SCRIPT_CHECKOUT_ROOT" "$TMPBASE/js/x.js" js)"
assert_eq "recognized-only js: $got" "recognized-only js: rc=78 launched=0"
has_line "js: UNSUPPORTED line" "$(cat "$TMPBASE/lch-js.out" 2>/dev/null)" "UNSUPPORTED: $TMPBASE/js/x.js (language: js; not run)"
got="$(lch "$FX_SUITE" "$SU/x.sh" bash)"
assert_eq "bash control: $got" "bash control: rc=0 launched=1"
case_end

# suite_co <tag> <js> — checkout co-<tag> whose fake-suite entry is edited by <js>, with one
# suite tests/s1 holding a.fakesuite; sets SCO to the checkout.
suite_co() {
  SCO="$TMPBASE/co-$1"
  fx_table_edit "$FIXTURES/fake-suite.json" "$TMPBASE/fake-suite-$1.json" "$2"
  fx_checkout "$SCO" "$TMPBASE/fake-suite-$1.json"
  mkdir -p "$SCO/tests/s1"
  : >"$SCO/tests/s1/fake.root"
  echo "# t" >"$SCO/tests/s1/a.fakesuite"
}

case_begin "suite-prepare-failure-and-missing-tool" "bin/lib/run-all-launch.sh"
suite_co pfail 't.entries[1].launch.prepare = ["bash", "-c", "echo prep >> prep.log; exit 3"];'
got="$(lch "$SCO" "$SCO/tests/s1/a.fakesuite" pfail)"
assert_eq "failing prepare: ${got%% *}" "failing prepare: rc=3"
assert_eq "failing prepare ran: $(lines_of "$SCO/tests/s1/prep.log")" "failing prepare ran: prep "
assert_eq "command after failing prepare: $(lines_of "$SCO/tests/s1/run.log")" "command after failing prepare: <absent>"
suite_co tool 't.entries[1].launch.requires = "no-such-tool-tlr";'
got="$(lch "$SCO" "$SCO/tests/s1/a.fakesuite" tool)"
assert_eq "missing tool: $got" "missing tool: rc=77 launched=0"
has_line "missing tool: SKIP line" "$(cat "$TMPBASE/lch-tool.out" 2>/dev/null)" "SKIP: no-such-tool-tlr not on PATH"
assert_eq "missing tool ran nothing: $(lines_of "$SCO/tests/s1/prep.log")" "missing tool ran nothing: <absent>"
case_end

case_begin "suite-timeout-bounds-prepare-and-command" "bin/lib/run-all-launch.sh"
# timeoutSeconds (2) bounds prepare and command alike; a prepare that overruns stops the launch
# before the command. rc 124 (timeout) and 142 (perl alarm) both mean the wrapper cut it off.
timed_out() { if [ "$1" = rc=124 ] || [ "$1" = rc=142 ]; then printf 'timed out'; else printf '%s' "$1"; fi; }
suite_co pslow 't.entries[1].launch.timeoutSeconds = 2; t.entries[1].launch.prepare = ["bash", "-c", "echo prep >> prep.log; sleep 8"];'
got="$(lch "$SCO" "$SCO/tests/s1/a.fakesuite" pslow)"
assert_eq "prepare overrun: $(timed_out "${got%% *}")" "prepare overrun: timed out"
assert_eq "prepare overrun prep.log: $(lines_of "$SCO/tests/s1/prep.log")" "prepare overrun prep.log: prep "
assert_eq "command after prepare overrun: $(lines_of "$SCO/tests/s1/run.log")" "command after prepare overrun: <absent>"
suite_co cslow 't.entries[1].launch.timeoutSeconds = 2; t.entries[1].launch.command = ["bash", "-c", "echo start >> run.log; sleep 8; echo end >> run.log"];'
got="$(lch "$SCO" "$SCO/tests/s1/a.fakesuite" cslow)"
assert_eq "command overrun: $(timed_out "${got%% *}")" "command overrun: timed out"
assert_eq "command overrun prep.log: $(lines_of "$SCO/tests/s1/prep.log")" "command overrun prep.log: prep "
assert_eq "command overrun run.log: $(lines_of "$SCO/tests/s1/run.log")" "command overrun run.log: start "
case_end

case_begin "baseline-uses-base-table" "bin/lib/run-tests-baseline-exec.sh"
# The parent loads cur's table; rtb_exec_one must still launch base's test with base's table.
BL_BASE="$TMPBASE/bl/base"
BL_CUR="$TMPBASE/bl/cur"
fx_table_edit "$TABLE" "$TMPBASE/base-table.json" 't.entries.find((e) => e.id === "bash").launch.command = ["bash", "-c", "echo BASE_TABLE_MARK; exec bash \"$0\"", "{path}"];'
fx_checkout "$BL_BASE" "$TMPBASE/base-table.json"
fx_checkout "$BL_CUR"
for co in "$BL_BASE" "$BL_CUR"; do
  mkdir -p "$co/tests/bin"
  printf '%s\n' 'echo T_RAN' >"$co/tests/bin/t.sh"
done
bl_run() {
  tlr_bash "$BL_CUR" 'tlr_load || exit 96; . "$1/bin/lib/run-tests-baseline-exec.sh" || exit 95
rtb_exec_one "$2" tests/bin/t.sh 60 "$3" || exit 94; cat "$3/1.out"' "$BL_CUR" "$1" "$TMPBASE/bl/log-$2" | tr '\n' ' '
}
assert_eq "base checkout: $(bl_run "$BL_BASE" base)" "base checkout: BASE_TABLE_MARK T_RAN "
assert_eq "cur checkout: $(bl_run "$BL_CUR" cur)" "cur checkout: T_RAN "
case_end

case_begin "retire-unit-sibling-dir" "bin/lib/test-retire-predicate.sh"
# Only an entry with siblingSuiteDir (bash) takes the same-name directory into the unit.
UN="$TMPBASE/unit"
mkdir -p "$UN/tests/hooks/a" "$UN/tests/hooks/b" "$UN/tests/hooks/test_c" "$UN/tests/hooks/d"
for f in a.sh a/x b.Tests.ps1 b/x test_c.py test_c/x d.zzz d/x; do : >"$UN/tests/hooks/$f"; done
got="$(tlr_bash "$SCRIPT_CHECKOUT_ROOT" '. "$1/bin/lib/test-retire-predicate.sh" || exit 95
for rel in tests/hooks/a.sh tests/hooks/b.Tests.ps1 tests/hooks/test_c.py tests/hooks/d.zzz; do
  trp_unit_of "$2" "$rel" 0; printf "[%s|%s]" "${TRP_UNIT_PATHS[*]}" "$TRP_GC"
done
trp_unit_of "$2" tests/hooks/a.sh 1; printf "[%s|%s]" "${TRP_UNIT_PATHS[*]}" "$TRP_GC"' "$SCRIPT_CHECKOUT_ROOT" "$UN")"
assert_eq "$got" "[tests/hooks/a.sh tests/hooks/a|1][tests/hooks/b.Tests.ps1|1][tests/hooks/test_c.py|1][tests/hooks/d.zzz|1][|0]"
case_end
