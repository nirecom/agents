# tests/bin/feature-2501-launch-classify/exec.sh
# Tests: bin/lib/run-all-launch.sh
# Tags: TL2, bin, run-all, launch, unrunnable, timeout, scope:issue-specific
# run_all_exec through a fixture checkout: missing requires -> UNRUNNABLE (rc 79 + marker),
# {wrapper}/{minVersion} substitution, the result-dir env reaching only the child, the optional
# result dir, the RUN_ALL_TIMEOUT_SECONDS bound (a `# Timeout:` header is ignored), and parallel
# launches keeping their records apart.
# Sourced by the dispatcher.

echo ""
echo "=== run_all_exec ==="

CO="$TMPBASE/co"
fx_co "$CO" missing || fail "fixture checkout (missing)" "fx_co failed"
COW="$TMPBASE/co-wrap"

# m-env.sh prints the result-dir env it received (it does not source the harness, which unsets it).
cat >"$CO/tests/bin/m-env.sh" <<'EOF'
printf 'rdir=%s\n' "${RUN_ALL_RESULT_DIR-<unset>}"
printf 'rowner=%s\n' "${RUN_ALL_RESULT_OWNER-<unset>}"
printf 'zero=%s\n' "$0"
EOF
printf '%s\n' 'echo should-not-run' >"$CO/tests/bin/t.fxmiss"

case_begin "missing-requires-is-unrunnable" "bin/lib/run-all-launch.sh"
mkdir -p "$TMPBASE/res-miss"
rae miss "$CO" "$CO/tests/bin/t.fxmiss" "$TMPBASE/res-miss"
K="$TMPBASE/rae-miss.kv"
assert_eq "missing requires: $(rae_sum miss) launched=$(kv launched "$K")" "missing requires: rc=79 state=UNRUNNABLE launched=0"
assert_eq "missing requires: RUN_ALL_EXEC_MISSING=$(kv missing "$K")" "missing requires: RUN_ALL_EXEC_MISSING=no-such-tool-2501"
assert_eq "marker: $(file_text "$TMPBASE/res-miss/unrunnable")" "marker: no-such-tool-2501 "
has_out="$(grep -c 'UNRUNNABLE: missing no-such-tool-2501' "$TMPBASE/rae-miss.out" 2>/dev/null || true)"
assert_eq "out line count: ${has_out:-0}" "out line count: 1"
if grep -q 'should-not-run' "$TMPBASE/rae-miss.out" 2>/dev/null; then
  fail "missing requires launched the test"
else
  pass "missing requires launched nothing"
fi
case_end

# The executable prepare / command start with is a launch need too: absent from PATH it is
# UNRUNNABLE, where launching it anyway would report the 127 as the test's own FAIL.
COX="$TMPBASE/co-exe"
fx_co "$COX" exe || fail "fixture checkout (exe)" "fx_co failed"
mkdir -p "$COX/tests/bin/sx"
: >"$COX/tests/bin/sx/fxsuite.marker"
for x in "t.fxnocmd" "t.fxboth" "t.fxfilenoprep" "sx/t.fxnoprep" "sx/t.fxsuiteok"; do
  printf '%s\n' 'echo should-not-run' >"$COX/tests/bin/$x"
done

# name | test file | want "rc state launched" | want RUN_ALL_EXEC_MISSING (also the marker and the out line)
EXE_ROWS=(
  'missing-command-exe|t.fxnocmd|rc=79 state=UNRUNNABLE launched=0|no-such-cmd-2501'
  'missing-prepare-exe|sx/t.fxnoprep|rc=79 state=UNRUNNABLE launched=0|no-such-prep-2501'
  'missing-file-prepare-exe|t.fxfilenoprep|rc=79 state=UNRUNNABLE launched=0|no-such-prep-2501'
  'requires-outranks-command|t.fxboth|rc=79 state=UNRUNNABLE launched=0|no-such-req-2501'
)

case_begin "missing-launch-executable-is-unrunnable" "bin/lib/run-all-launch.sh"
for row in "${EXE_ROWS[@]}"; do
  IFS='|' read -r ex_name ex_file ex_want ex_miss <<<"$row"
  mkdir -p "$TMPBASE/res-$ex_name"
  rae "$ex_name" "$COX" "$COX/tests/bin/$ex_file" "$TMPBASE/res-$ex_name"
  K="$TMPBASE/rae-$ex_name.kv"
  assert_eq "$ex_name: $(rae_sum "$ex_name") launched=$(kv launched "$K")" "$ex_name: $ex_want"
  assert_eq "$ex_name: RUN_ALL_EXEC_MISSING=$(kv missing "$K")" "$ex_name: RUN_ALL_EXEC_MISSING=$ex_miss"
  assert_eq "$ex_name marker: $(file_text "$TMPBASE/res-$ex_name/unrunnable")" "$ex_name marker: $ex_miss "
  assert_eq "$ex_name out: $(file_text "$TMPBASE/rae-$ex_name.out")" "$ex_name out: UNRUNNABLE: missing $ex_miss "
done
case_end

case_begin "present-launch-executables-launch" "bin/lib/run-all-launch.sh"
mkdir -p "$TMPBASE/res-suiteok"
rae suiteok "$COX" "$COX/tests/bin/sx/t.fxsuiteok" "$TMPBASE/res-suiteok"
K="$TMPBASE/rae-suiteok.kv"
assert_eq "all present: $(rae_sum suiteok) launched=$(kv launched "$K")" "all present: rc=0 state=PASS launched=1"
assert_eq "all present: RUN_ALL_EXEC_MISSING=[$(kv missing "$K")]" "all present: RUN_ALL_EXEC_MISSING=[]"
assert_eq "all present out: $(file_text "$TMPBASE/rae-suiteok.out")" "all present out: suite-prep-ran-2501 suite-cmd-ran-2501 "
if [ -e "$TMPBASE/res-suiteok/unrunnable" ]; then
  fail "all present: no unrunnable marker" "marker: $(file_text "$TMPBASE/res-suiteok/unrunnable")"
else
  pass "all present: no unrunnable marker"
fi
case_end

# Security round: a suite's executables are looked up from the suite root, where the launch runs
# them — `./runner-2501` exists there only, and the caller stands elsewhere.
printf '%s\n' 'echo should-not-run' >"$COX/tests/bin/sx/t.fxsuitelocal"
printf '%s\n' '#!/usr/bin/env bash' 'echo suite-local-runner-ran-2501' >"$COX/tests/bin/sx/runner-2501"
chmod +x "$COX/tests/bin/sx/runner-2501"
case_begin "suite-local-executable-is-found-from-the-suite-root" "bin/lib/run-all-launch.sh"
mkdir -p "$TMPBASE/res-suitelocal" "$TMPBASE/elsewhere"
(cd "$TMPBASE/elsewhere" && rae suitelocal "$COX" "$COX/tests/bin/sx/t.fxsuitelocal" "$TMPBASE/res-suitelocal")
K="$TMPBASE/rae-suitelocal.kv"
assert_eq "suite-local: $(rae_sum suitelocal) launched=$(kv launched "$K")" "suite-local: rc=0 state=PASS launched=1"
assert_eq "suite-local out: $(file_text "$TMPBASE/rae-suitelocal.out")" "suite-local out: suite-local-runner-ran-2501 "
if [ -e "$TMPBASE/res-suitelocal/unrunnable" ]; then
  fail "suite-local: no unrunnable marker" "marker: $(file_text "$TMPBASE/res-suitelocal/unrunnable")"
else
  pass "suite-local: no unrunnable marker"
fi
case_end

case_begin "wrapper-and-min-version-substitution" "bin/lib/run-all-launch.sh"
fx_co "$COW" wrap || fail "fixture checkout (wrap)" "fx_co failed"
printf '%s\n' 'echo never-run-directly' >"$COW/tests/bin/w.fxwrap"
mkdir -p "$TMPBASE/res-wrap"
rae wrap "$COW" "$COW/tests/bin/w.fxwrap" "$TMPBASE/res-wrap"
O="$TMPBASE/rae-wrap.out"
assert_eq "wrapper run: $(rae_sum wrap)" "wrapper run: rc=0 state=PASS"
w="$(kv wrapper "$O")"
case "$w" in
  /* | [A-Za-z]:/*) pass "wrapper path is absolute: $w" ;;
  *) fail "wrapper path is absolute" "got [$w]" ;;
esac
if [ "$w" != "<absent>" ] && [ -f "$w" ]; then
  pass "wrapper path exists"
else
  fail "wrapper path exists" "got [$w]"
fi
assert_eq "wrapper resolved from the checkout: ${w##*/}" "wrapper resolved from the checkout: fx-echo-2501.sh"
assert_eq "wrapper argc: $(kv argc "$O")" "wrapper argc: 2"
assert_eq "{nativePath}: $(kv arg1 "$O")" "{nativePath}: $(np "$COW/tests/bin/w.fxwrap")"
assert_eq "{minVersion} is the bare version: $(kv arg2 "$O")" "{minVersion} is the bare version: 1.2"
assert_eq "wrapper sees RUN_ALL_RESULT_DIR: $(kv rdir "$O")" "wrapper sees RUN_ALL_RESULT_DIR: $(np "$TMPBASE/res-wrap")"
assert_eq "wrapper sees RUN_ALL_RESULT_OWNER: $(kv rowner "$O")" "wrapper sees RUN_ALL_RESULT_OWNER: $COW/tests/bin/w.fxwrap"
case_end

# A suite runs in its suite root, yet {wrapper} still names the checkout's wrapper.
case_begin "suite-entry-runs-its-wrapper" "bin/lib/run-all-launch.sh"
mkdir -p "$COW/tests/bin/sw" "$TMPBASE/res-suitewrap"
: >"$COW/tests/bin/sw/fxsuite.marker"
printf '%s\n' 'echo never-run-directly' >"$COW/tests/bin/sw/t.fxsuitewrap"
(cd "$TMPBASE" && rae suitewrap "$COW" "$COW/tests/bin/sw/t.fxsuitewrap" "$TMPBASE/res-suitewrap")
O="$TMPBASE/rae-suitewrap.out"
assert_eq "suite wrapper run: $(rae_sum suitewrap) launched=$(kv launched "$TMPBASE/rae-suitewrap.kv")" "suite wrapper run: rc=0 state=PASS launched=1"
w="$(kv wrapper "$O")"
if [ "${w##*/}" = "fx-echo-2501.sh" ] && [ -f "$w" ]; then
  pass "suite wrapper path is the checkout's file: $w"
else
  fail "suite wrapper path is the checkout's file" "got [$w]"
fi
assert_eq "suite wrapper argv: argc=$(kv argc "$O") arg1=$(kv arg1 "$O")" "suite wrapper argv: argc=1 arg1=1.2"
case_end

case_begin "result-env-reaches-only-the-child" "bin/lib/run-all-launch.sh"
mkdir -p "$TMPBASE/res-env"
rae env "$CO" "$CO/tests/bin/m-env.sh" "$TMPBASE/res-env"
O="$TMPBASE/rae-env.out"
K="$TMPBASE/rae-env.kv"
assert_eq "env run: $(rae_sum env)" "env run: rc=0 state=PASS"
assert_eq "child RUN_ALL_RESULT_DIR: $(kv rdir "$O")" "child RUN_ALL_RESULT_DIR: $(np "$TMPBASE/res-env")"
# The owner is the {path} string itself, so a bash test compares it with its own $0.
assert_eq "child RUN_ALL_RESULT_OWNER: $(kv rowner "$O")" "child RUN_ALL_RESULT_OWNER: $(kv zero "$O")"
assert_eq "owner is the path passed: $(kv rowner "$O")" "owner is the path passed: $CO/tests/bin/m-env.sh"
assert_eq "caller after the call: rd=$(kv rd "$K") ro=$(kv ro "$K")" "caller after the call: rd=<unset> ro=<unset>"
case_end

case_begin "result-dir-is-optional" "bin/lib/run-all-launch.sh"
rae noarg "$CO" "$CO/tests/bin/m-env.sh"
O="$TMPBASE/rae-noarg.out"
assert_eq "omitted result dir: $(rae_sum noarg)" "omitted result dir: rc=0 state=PASS"
tmp_rd="$(kv rdir "$O")"
case "$tmp_rd" in
  "<unset>" | "<absent>" | "") fail "omitted result dir: child got a temp result dir" "got [$tmp_rd]" ;;
  *)
    if [ -e "$tmp_rd" ]; then
      fail "omitted result dir: temp dir removed after the call" "still present: $tmp_rd"
    else
      pass "omitted result dir: temp dir removed after the call"
    fi
    ;;
esac
case_end

cat >"$CO/tests/bin/m-timeout.sh" <<'EOF'
#!/usr/bin/env bash
sleep 10
echo slept-through
EOF

case_begin "env-timeout-bounds-a-bash-test" "bin/lib/run-all-launch.sh"
mkdir -p "$TMPBASE/res-to"
(
  export RUN_ALL_TIMEOUT_SECONDS=2
  rae to "$CO" "$CO/tests/bin/m-timeout.sh" "$TMPBASE/res-to"
)
K="$TMPBASE/rae-to.kv"
assert_eq "env timeout: $(rae_sum to)" "env timeout: rc=124 state=TIMEOUT"
# #2501 D3-2: the timer's firing is recorded as a fact, the timed-out marker in the result dir.
if [ -e "$TMPBASE/res-to/timed-out" ]; then pass "env timeout: timed-out marker written"
else fail "env timeout: timed-out marker written" "$(ls -A "$TMPBASE/res-to" 2>&1 | tr '\n' ' ')"; fi
el="$(kv el "$K")"
case "$el" in
  '' | *[!0-9]*) fail "env timeout: elapsed" "got [$el]" ;;
  *)
    if [ "$el" -le 6 ]; then
      pass "env timeout: stopped within 6 s (${el}s)"
    else
      fail "env timeout: stopped within 6 s" "took ${el}s"
    fi
    ;;
esac
if grep -q slept-through "$TMPBASE/rae-to.out" 2>/dev/null; then
  fail "env timeout: test ran to the end"
else
  pass "env timeout: test cut off"
fi
case_end

# One limit covers a suite unit: prepare (2 s) and command (4 s) each fit in 5 s, their sum does not.
printf '%s\n' 'echo should-not-run' >"$COX/tests/bin/sx/t.fxsuiteslow"
case_begin "suite-timeout-covers-prepare-and-command" "bin/lib/run-all-launch.sh"
mkdir -p "$TMPBASE/res-slow"
(
  export RUN_ALL_TIMEOUT_SECONDS=5
  rae slow "$COX" "$COX/tests/bin/sx/t.fxsuiteslow" "$TMPBASE/res-slow"
)
assert_eq "suite over its limit: $(rae_sum slow)" "suite over its limit: rc=124 state=TIMEOUT"
assert_eq "suite command cut off: $(grep -c suite-slow-cmd-done-2501 "$TMPBASE/rae-slow.out" 2>/dev/null || true)" \
  "suite command cut off: 0"
case_end

# Security round: prepare is the entry's, not the suite's — a file unit runs it before each file,
# returns its failure without running the command (launched=0, like a suite unit), and shares the
# one time limit with the command.
printf '%s\n' 'echo file-cmd-ran-2501' >"$COX/tests/bin/t.fxfileprep"
printf '%s\n' 'echo should-not-run' >"$COX/tests/bin/t.fxfileprepfail"
printf '%s\n' 'sleep 4' 'echo file-slow-cmd-done-2501' >"$COX/tests/bin/t.fxfileslow"
case_begin "file-unit-runs-prepare-under-the-same-contract" "bin/lib/run-all-launch.sh"
mkdir -p "$TMPBASE/res-fprep" "$TMPBASE/res-fprepfail" "$TMPBASE/res-fslow"
rae fprep "$COX" "$COX/tests/bin/t.fxfileprep" "$TMPBASE/res-fprep"
assert_eq "file prepare: $(rae_sum fprep) launched=$(kv launched "$TMPBASE/rae-fprep.kv")" "file prepare: rc=0 state=PASS launched=1"
assert_eq "file prepare out: $(file_text "$TMPBASE/rae-fprep.out")" \
  "file prepare out: file-prep-ran-2501 $COX/tests/bin/t.fxfileprep file-cmd-ran-2501 "
rae fprepfail "$COX" "$COX/tests/bin/t.fxfileprepfail" "$TMPBASE/res-fprepfail"
assert_eq "file prepare fails: state=$(kv state "$TMPBASE/rae-fprepfail.kv") launched=$(kv launched "$TMPBASE/rae-fprepfail.kv")" \
  "file prepare fails: state=FAIL launched=0"
assert_eq "file prepare fails out: $(file_text "$TMPBASE/rae-fprepfail.out")" "file prepare fails out: file-prep-failed-2501 "
# run_all_exec returns the prepare's own rc, and the launcher records the failure as an empty marker.
assert_eq "file prepare fails: $(rae_full fprepfail)" "file prepare fails: rc=7 state=FAIL execrc=7 launched=0"
assert_eq "file prepare fails markers: $(ls -A "$TMPBASE/res-fprepfail" 2>&1 | tr '\n' ' ')" \
  "file prepare fails markers: prepare-failed "
if [ -f "$TMPBASE/res-fprepfail/prepare-failed" ] && [ ! -s "$TMPBASE/res-fprepfail/prepare-failed" ]; then
  pass "file prepare fails: prepare-failed marker is empty"
else
  fail "file prepare fails: prepare-failed marker is empty" "$(file_text "$TMPBASE/res-fprepfail/prepare-failed")"
fi
(
  export RUN_ALL_TIMEOUT_SECONDS=5
  rae fslow "$COX" "$COX/tests/bin/t.fxfileslow" "$TMPBASE/res-fslow"
)
assert_eq "file over its limit: $(rae_sum fslow)" "file over its limit: rc=124 state=TIMEOUT"
assert_eq "file command cut off: $(grep -c file-slow-cmd-done-2501 "$TMPBASE/rae-fslow.out" 2>/dev/null || true)" \
  "file command cut off: 0"
case_end

# A failed prepare is the same on both units; its pass or skip rc is never the test's (77 becomes 1).
printf '%s\n' 'echo should-not-run' >"$COX/tests/bin/t.fxfileprep77"
printf '%s\n' 'echo should-not-run' >"$COX/tests/bin/sx/t.fxsuiteprepfail"
# name | test file | want rae_full | want out
PF_ROWS=(
  'pf-file-77|t.fxfileprep77|rc=1 state=FAIL execrc=1 launched=0|file-prep-skipped-2501 '
  'pf-suite|sx/t.fxsuiteprepfail|rc=7 state=FAIL execrc=7 launched=0|suite-prep-failed-2501 '
)

case_begin "prepare-failure-returns-fail-on-file-and-suite-units" "bin/lib/run-all-launch.sh"
for row in "${PF_ROWS[@]}"; do
  IFS='|' read -r pf_name pf_file pf_want pf_out <<<"$row"
  mkdir -p "$TMPBASE/res-$pf_name"
  rae "$pf_name" "$COX" "$COX/tests/bin/$pf_file" "$TMPBASE/res-$pf_name"
  assert_eq "$pf_name: $(rae_full "$pf_name")" "$pf_name: $pf_want"
  assert_eq "$pf_name out: $(file_text "$TMPBASE/rae-$pf_name.out")" "$pf_name out: $pf_out"
  assert_eq "$pf_name markers: $(ls -A "$TMPBASE/res-$pf_name" 2>&1 | tr '\n' ' ')" "$pf_name markers: prepare-failed "
  if [ -f "$TMPBASE/res-$pf_name/prepare-failed" ] && [ ! -s "$TMPBASE/res-$pf_name/prepare-failed" ]; then
    pass "$pf_name: prepare-failed marker is empty"
  else
    fail "$pf_name: prepare-failed marker is empty" "$(file_text "$TMPBASE/res-$pf_name/prepare-failed")"
  fi
done
case_end

# A legacy `# Timeout:` header line is plain text now: with no env and a null bash entry, no kill.
cat >"$CO/tests/bin/m-hdr.sh" <<'EOF'
#!/usr/bin/env bash
# Timeout: 1
sleep 4
echo slept-through
EOF

case_begin "timeout-header-is-ignored" "bin/lib/run-all-launch.sh"
mkdir -p "$TMPBASE/res-hdr"
rae hdr "$CO" "$CO/tests/bin/m-hdr.sh" "$TMPBASE/res-hdr"
assert_eq "header without env: $(rae_sum hdr)" "header without env: rc=0 state=PASS"
assert_eq "header without env: ran to the end: $(grep -c slept-through "$TMPBASE/rae-hdr.out" 2>/dev/null || true)" \
  "header without env: ran to the end: 1"
case_end

# Two harness tests that interleave their cases in time.
for side in a b; do
  cat >"$CO/tests/bin/m-par-$side.sh" <<'EOF'
. "${0%/*}/../lib/harness.sh"
side="${0##*/m-par-}"
side="${side%.sh}"
case_begin "par-$side-1" "bin/fx.sh"
sleep 1
pass "one"
case_end
case_begin "par-$side-2" "bin/fx.sh"
sleep 1
pass "two"
case_end
exit 0
EOF
done

case_begin "parallel-launches-keep-records-apart" "bin/lib/run-all-launch.sh"
mkdir -p "$TMPBASE/res-pa" "$TMPBASE/res-pb"
rae pa "$CO" "$CO/tests/bin/m-par-a.sh" "$TMPBASE/res-pa" &
pa_pid=$!
rae pb "$CO" "$CO/tests/bin/m-par-b.sh" "$TMPBASE/res-pb" &
pb_pid=$!
FX_PIDS="$FX_PIDS $pa_pid $pb_pid"
wait "$pa_pid" "$pb_pid" 2>/dev/null || true
assert_eq "a: $(rae_sum pa) | $(res_of "$TMPBASE/res-pa/cases.tsv")" "a: rc=0 state=PASS | 1=PASS:par-a-1 2=PASS:par-a-2 "
assert_eq "b: $(rae_sum pb) | $(res_of "$TMPBASE/res-pb/cases.tsv")" "b: rc=0 state=PASS | 1=PASS:par-b-1 2=PASS:par-b-2 "
case_end
