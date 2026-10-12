# tests/bin/feature-2501-launch-classify/matrix.sh
# Tests: bin/lib/run-all-launch.sh
# Tags: TL2, bin, run-all, launch, case-results, regression-matrix, timeout, scope:issue-specific, classify
# The bash column of the regression matrix (detail plan "Test plan"): each fixture runs through
# run_all_exec with a result dir; the normalized rc, the state and the cases.tsv records are checked.
# Raw records are checked here; resolving OPEN / UNOBSERVED is the report's job.
# Sourced by the dispatcher (after exec.sh, which builds $CO).

echo ""
echo "=== regression matrix (bash) ==="

MX="$CO/tests/bin"

cat >"$MX/mx-skip-pass.sh" <<'EOF'
. "${0%/*}/../lib/harness.sh"
case_begin "a-pass" "bin/fx.sh"
pass "ok"
case_end
case_begin "b-skip" "bin/fx.sh"
skip "not here"
case_end
[ "$FAIL" -gt 0 ] && exit 1
exit 0
EOF

cat >"$MX/mx-all-skip.sh" <<'EOF'
. "${0%/*}/../lib/harness.sh"
case_begin "a-skip" "bin/fx.sh"
skip "one"
case_end
case_begin "b-skip" "bin/fx.sh"
skip "two"
case_end
exit 0
EOF

cat >"$MX/mx-unobserved.sh" <<'EOF'
. "${0%/*}/../lib/harness.sh"
MY_COUNT=0
case_begin "custom-counter" "bin/fx.sh"
echo "PASS: counted by hand"
MY_COUNT=$((MY_COUNT + 1))
case_end
exit 0
EOF

cat >"$MX/mx-deferred-skip.sh" <<'EOF'
. "${0%/*}/../lib/harness.sh"
case_begin "a-queued" "bin/fx.sh"
case_end
case_begin "b-skip" "bin/fx.sh"
skip "not here"
case_end
pass "flushed after case_end"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
EOF

cat >"$MX/mx-nocase.sh" <<'EOF'
. "${0%/*}/../lib/harness.sh"
echo "nothing asserted"
exit 0
EOF

cat >"$MX/mx-exit77.sh" <<'EOF'
. "${0%/*}/../lib/harness.sh"
echo "SKIP: whole file"
exit 77
EOF

for n in 77 256; do
  cat >"$MX/mx-fail$n.sh" <<'EOF'
. "${0%/*}/../lib/harness.sh"
want="${0##*/mx-fail}"
want="${want%.sh}"
case_begin "many-fails" "bin/fx.sh"
i=0
while [ "$i" -lt "$want" ]; do
  fail "f$i"
  i=$((i + 1))
done
case_end
[ "$FAIL" -gt 0 ] && exit 1
exit 0
EOF
done

cat >"$MX/mx-exit79.sh" <<'EOF'
echo "a test that exits 79 on its own"
exit 79
EOF

cat >"$MX/mx-open-fail.sh" <<'EOF'
. "${0%/*}/../lib/harness.sh"
case_begin "dangling" "bin/fx.sh"
pass "before the exit"
exit 1
EOF

cat >"$MX/mx-open-ok.sh" <<'EOF'
. "${0%/*}/../lib/harness.sh"
case_begin "dangling" "bin/fx.sh"
pass "before the exit"
exit 0
EOF

# mx <tag> — run mx-<tag>.sh with its own result dir res-mx-<tag>.
mx() {
  mkdir -p "$TMPBASE/res-mx-$1"
  rae "mx-$1" "$CO" "$MX/mx-$1.sh" "$TMPBASE/res-mx-$1"
}
mx_res() { res_of "$TMPBASE/res-mx-$1/cases.tsv"; }

case_begin "matrix-skip-one-pass-one" "bin/lib/run-all-launch.sh"
mx skip-pass
assert_eq "skip+pass: $(rae_sum mx-skip-pass) | $(mx_res skip-pass)" "skip+pass: rc=0 state=PASS | 1=PASS:a-pass 2=SKIP:b-skip "
case_end

case_begin "matrix-all-explicit-skip" "bin/lib/run-all-launch.sh"
mx all-skip
assert_eq "all skip: $(rae_sum mx-all-skip) | $(mx_res all-skip)" "all skip: rc=77 state=SKIP | 1=SKIP:a-skip 2=SKIP:b-skip "
case_end

case_begin "matrix-custom-counter-is-unobserved" "bin/lib/run-all-launch.sh"
mx unobserved
assert_eq "custom counter: $(rae_sum mx-unobserved) | $(mx_res unobserved)" "custom counter: rc=0 state=PASS | 1=UNOBSERVED:custom-counter "
case_end

case_begin "matrix-deferred-pass-with-skip-is-pass" "bin/lib/run-all-classify.sh"
mx deferred-skip
assert_eq "deferred pass + skip: $(rae_sum mx-deferred-skip) | $(mx_res deferred-skip)" "deferred pass + skip: rc=0 state=PASS | 1=UNOBSERVED:a-queued 2=SKIP:b-skip "
case_end

case_begin "matrix-no-case-no-assertion" "bin/lib/run-all-launch.sh"
mx nocase
assert_eq "no case: $(rae_sum mx-nocase)" "no case: rc=0 state=PASS"
if [ -s "$TMPBASE/res-mx-nocase/cases.tsv" ]; then
  fail "no case: no records" "$(file_text "$TMPBASE/res-mx-nocase/cases.tsv")"
else
  pass "no case: no records"
fi
case_end

case_begin "matrix-exit-77-is-skip" "bin/lib/run-all-launch.sh"
mx exit77
assert_eq "exit 77: $(rae_sum mx-exit77)" "exit 77: rc=77 state=SKIP"
case_end

case_begin "matrix-77-and-256-failures-are-fail" "bin/lib/run-all-launch.sh"
mx fail77
assert_eq "77 failures: $(rae_sum mx-fail77) | $(mx_res fail77)" "77 failures: rc=1 state=FAIL | 1=FAIL:many-fails "
mx fail256
assert_eq "256 failures: $(rae_sum mx-fail256) | $(mx_res fail256)" "256 failures: rc=1 state=FAIL | 1=FAIL:many-fails "
case_end

case_begin "matrix-exit-79-without-marker-is-fail" "bin/lib/run-all-launch.sh"
mx exit79
assert_eq "exit 79: state=$(kv state "$TMPBASE/rae-mx-exit79.kv") launched=$(kv launched "$TMPBASE/rae-mx-exit79.kv")" "exit 79: state=FAIL launched=1"
if [ -e "$TMPBASE/res-mx-exit79/unrunnable" ]; then
  fail "exit 79: no unrunnable marker" "marker written"
else
  pass "exit 79: no unrunnable marker"
fi
case_end

case_begin "matrix-unfinished-case-leaves-open" "bin/lib/run-all-launch.sh"
mx open-fail
assert_eq "open + exit 1: $(rae_sum mx-open-fail) | $(mx_res open-fail)" "open + exit 1: rc=1 state=FAIL | 1=OPEN:dangling "
mx open-ok
assert_eq "open + exit 0: $(rae_sum mx-open-ok) | $(mx_res open-ok)" "open + exit 0: rc=0 state=PASS | 1=OPEN:dangling "
case_end

# A failed case whose file forgets to exit non-zero: the record alone makes the file FAIL.
cat >"$MX/mx-fail-exit0.sh" <<'EOF'
. "${0%/*}/../lib/harness.sh"
case_begin "a-pass" "bin/fx.sh"
pass "ok"
case_end
case_begin "b-fail" "bin/fx.sh"
fail "broken"
case_end
exit 0
EOF

case_begin "matrix-failed-case-with-exit-0-is-fail" "bin/lib/run-all-classify.sh"
mx fail-exit0
assert_eq "fail + exit 0: $(rae_sum mx-fail-exit0) | $(mx_res fail-exit0)" "fail + exit 0: rc=1 state=FAIL | 1=PASS:a-pass 2=FAIL:b-fail "
case_end

# A test that exits with a signal-shaped rc on its own, after 1 s.
for n in 124 143; do
  printf '%s\n' 'sleep 1' "exit $n" >"$MX/mx-sig$n.sh"
done

case_begin "matrix-signal-rc-without-timeout-is-fail" "bin/lib/run-all-launch.sh"
# The bash entry's timeoutSeconds is null and the env is unset: no deadline, so never TIMEOUT.
for n in 124 143; do
  mkdir -p "$TMPBASE/res-mx-sig$n-none"
  (
    unset RUN_ALL_TIMEOUT_SECONDS
    rae "mx-sig$n-none" "$CO" "$MX/mx-sig$n.sh" "$TMPBASE/res-mx-sig$n-none"
  )
  assert_eq "exit $n, no timeout: $(rae_sum "mx-sig$n-none") launched=$(kv launched "$TMPBASE/rae-mx-sig$n-none.kv")" \
    "exit $n, no timeout: rc=$n state=FAIL launched=1"
done
case_end

case_begin "matrix-signal-rc-before-deadline-is-fail" "bin/lib/run-all-launch.sh"
# #2501 C2: only the timer firing makes TIMEOUT. The same fixtures exit on their own 2 s before
# a 3 s deadline: the timer never fired, so no timed-out marker and the child's rc is a FAIL.
for n in 124 143; do
  mkdir -p "$TMPBASE/res-mx-sig$n-eff"
  (
    export RUN_ALL_TIMEOUT_SECONDS=3
    rae "mx-sig$n-eff" "$CO" "$MX/mx-sig$n.sh" "$TMPBASE/res-mx-sig$n-eff"
  )
  assert_eq "exit $n, 3 s timeout: $(rae_sum "mx-sig$n-eff")" "exit $n, 3 s timeout: rc=$n state=FAIL"
  if [ -e "$TMPBASE/res-mx-sig$n-eff/timed-out" ]; then
    fail "exit $n, 3 s timeout: no timed-out marker" "marker written although the timer never fired"
  else pass "exit $n, 3 s timeout: no timed-out marker"; fi
done
case_end
