# The language filter on append candidates (#2411), read from runs without --with-language:
# the filter does not depend on the flag. Sourced by tests/bin/feature-2411-route-language.sh.
# shellcheck shell=bash

echo ""
echo "=== filter: candidates by language ==="

case_begin "single-language-appends-only-to-a-test-in-it" "bin/lib/test-route-destination.sh"
expect "--sources src/one.js" "$(row "$N_SRC" 2)" append exact "$T/single_js.js"
expect "--test-file $T/single_js.sh" "$(row "$N_TF" 2)" append exact "$T/single_js.js"
expect "--test-file $T/single_js.js" "$(row "$N_TF" 3)" new no-candidate "-"
case_end

case_begin "single-language-with-only-bash-tests-is-new" "bin/lib/test-route-destination.sh"
expect "--sources src/two.js" "$(row "$N_SRC" 3)" new no-candidate "-"
expect "--test-file $T/only_bash.sh" "$(row "$N_TF" 4)" new no-candidate "-"
case_end

case_begin "several-languages-keep-tests-in-those-languages" "bin/lib/test-route-destination.sh"
expect "--sources src/m.sh,src/m.js" "$(row "$N_SRC" 4)" append exact "$T/multi.js,$T/multi.sh"
expect "--test-file $T/multi.Tests.ps1" "$(row "$N_TF" 5)" append exact "$T/multi.js,$T/multi.sh"
expect "--test-file $T/multi.sh" "$(row "$N_TF" 6)" append exact "$T/multi.js"
case_end

case_begin "several-languages-third-language-test-is-not-a-destination" "bin/lib/test-route-destination.sh"
expect "--sources src/p.sh,src/p.js" "$(row "$N_SRC" 5)" new no-candidate "-"
expect "--test-file $T/ponly.Tests.ps1" "$(row "$N_TF" 7)" new no-candidate "-"
case_end

case_begin "unsupported-query-is-not-filtered-by-language" "bin/lib/test-route-destination.sh"
expect "--sources docs/v.md" "$(row "$N_SRC" 6)" append exact "$T/docv.js,$T/docv.sh"
expect "--test-file $T/docv.sh" "$(row "$N_TF" 8)" append exact "$T/docv.js"
case_end

case_begin "mixed-query-filters-by-the-code-language" "bin/lib/test-route-destination.sh"
expect "--sources src/x.js,docs/x.md" "$(row "$N_SRC" 7)" append exact "$T/mix.js"
expect "--test-file $T/mix.sh" "$(row "$N_TF" 9)" append exact "$T/mix.js"
case_end

# Python queries: pytest tests are the destination, bash tests of the same source are not.
# pytest needs uv (launch.requires, a command -v check), so the queries run twice whatever the
# host has: once with a stub uv in front of BASE_PATH, once on BASE_PATH, which has no uv.
PY_SRC_Q=(src/pa.py src/pb.py src/pc.py)
PY_TF_Q=("$T/test_pa.py" "$T/test_pb.py" "$T/pc.sh")
UV_STUB_DIR="$(stub_dir "$TMPBASE/uv-stub" uv)"
PY_SRC=""; PY_TF=""; PY_SRC_RC=""; PY_TF_RC=""; UV_STUB_SEEN=""
PYN_SRC=""; PYN_TF=""; PYN_SRC_RC=""; PYN_TF_RC=""; PYN_RAN=0
if [ -n "$BASE_PATH" ]; then
  Q_PATH="$UV_STUB_DIR:$BASE_PATH"
  UV_STUB_SEEN="$(PATH="$Q_PATH" command -v uv)"
  run_q --sources "${PY_SRC_Q[@]}"; PY_SRC="$Q_OUT"; PY_SRC_RC="$Q_RC"
  run_q --test-file "${PY_TF_Q[@]}"; PY_TF="$Q_OUT"; PY_TF_RC="$Q_RC"
  Q_PATH="$BASE_PATH"
  run_q --sources "${PY_SRC_Q[@]}"; PYN_SRC="$Q_OUT"; PYN_SRC_RC="$Q_RC"
  run_q --test-file "${PY_TF_Q[@]}"; PYN_TF="$Q_OUT"; PYN_TF_RC="$Q_RC"
  PYN_RAN=1
fi
Q_PATH=""

case_begin "python-query-appends-only-to-a-pytest-test" "bin/lib/test-route-destination/language.sh"
assert_eq "uv stub resolves=$UV_STUB_SEEN" "uv stub resolves=$UV_STUB_DIR/uv"
assert_eq "uv present: python queries rc=$PY_SRC_RC/$PY_TF_RC" "uv present: python queries rc=0/0"
expect "uv present: --sources src/pa.py" "$(row "$PY_SRC" 0)" append exact "$T/test_pa.py,$T/test_pa2.py"
expect "uv present: --test-file $T/test_pa.py" "$(row "$PY_TF" 0)" append exact "$T/test_pa2.py"
expect "uv present: --sources src/pb.py" "$(row "$PY_SRC" 1)" append exact "$T/test_pb.py"
case_end

case_begin "python-query-with-only-bash-tests-is-new" "bin/lib/test-route-destination/language.sh"
expect "uv present: --test-file $T/test_pb.py" "$(row "$PY_TF" 1)" new no-candidate "-"
expect "uv present: --sources src/pc.py" "$(row "$PY_SRC" 2)" new no-candidate "-"
expect "uv present: --test-file $T/pc.sh" "$(row "$PY_TF" 2)" new no-candidate "-"
case_end

case_begin "python-query-without-uv-is-runtime-unavailable" "bin/lib/test-route-destination/language.sh"
if [ "$PYN_RAN" -ne 1 ]; then
  fail "PATH of tool wrappers" "$BASE_PATH_ERR"
else
  assert_eq "no uv: python queries rc=$PYN_SRC_RC/$PYN_TF_RC" "no uv: python queries rc=0/0"
  expect "no uv: --sources src/pa.py" "$(row "$PYN_SRC" 0)" new runtime-unavailable "-"
  expect "no uv: --test-file $T/test_pa.py" "$(row "$PYN_TF" 0)" new runtime-unavailable "-"
  expect "no uv: --sources src/pb.py" "$(row "$PYN_SRC" 1)" new runtime-unavailable "-"
  expect "no uv: --test-file $T/test_pb.py" "$(row "$PYN_TF" 1)" new runtime-unavailable "-"
  expect "no uv: --sources src/pc.py" "$(row "$PYN_SRC" 2)" new runtime-unavailable "-"
  expect "no uv: --test-file $T/pc.sh" "$(row "$PYN_TF" 2)" new runtime-unavailable "-"
fi
case_end

case_begin "runtime-absent-language-is-dropped" "bin/lib/test-route-destination.sh"
if [ "$R_RAN" -ne 1 ]; then
  fail "PATH of tool wrappers" "$BASE_PATH_ERR"
else
  assert_eq "pwsh present: rc/err=$RP_RC" "pwsh present: rc/err=0/"
  assert_eq "no pwsh: rc=$R_RC err=$R_ERR" "no pwsh: rc=0/0 err="
  expect "pwsh present: --sources src/r.ps1" "$(row "$RP_SRC" 0)" append exact "$T/rt.Tests.ps1"
  expect "pwsh present: --sources docs/r.md" "$(row "$RP_SRC" 2)" append exact "$T/rtd.Tests.ps1,$T/rtd.sh,$T/rtd2.sh"
  expect "no pwsh: --sources src/r.ps1" "$(row "$R_SRC" 0)" new runtime-unavailable "-"
  expect "no pwsh: --test-file $T/rt-probe.sh" "$(row "$R_TF" 0)" new runtime-unavailable "-"
  expect "no pwsh: --sources src/rm.sh,src/rm.ps1" "$(row "$R_SRC" 1)" append exact "$T/rtm.sh,$T/rtm2.sh"
  expect "no pwsh: --test-file $T/rtm.sh" "$(row "$R_TF" 1)" append exact "$T/rtm2.sh"
  expect "no pwsh: --sources docs/r.md" "$(row "$R_SRC" 2)" append exact "$T/rtd.sh,$T/rtd2.sh"
  expect "no pwsh: --test-file $T/rtd.sh" "$(row "$R_TF" 2)" append exact "$T/rtd2.sh"
fi
case_end
