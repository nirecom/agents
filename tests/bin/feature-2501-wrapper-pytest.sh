#!/usr/bin/env bash
# tests/bin/feature-2501-wrapper-pytest.sh
# Tests: bin/lib/test-wrappers/pytest.py
# Tags: scope:issue-specific, test-language-wrapper, pytest, run-all, result-dir, unrunnable, tl2
# pytest language wrapper (#2501 D4-2): exit-table normalization (rc 5 -> 77, all skipped -> 77,
# any failure -> 1, collection error -> 1 + FAIL record), version floor -> 79 + marker,
# xfail / xpass records, env removal before test code, cases.tsv.
set -u

# Pin to this checkout: the wrappers under test are the ones beside this file.
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$SCRIPT_CHECKOUT_ROOT"
. "$REPO_ROOT/tests/lib/harness.sh"

command -v uv >/dev/null 2>&1 || { echo "SKIP: uv not on PATH"; exit 77; }
if ! run_with_timeout 90 uv run --no-project --with "pytest>=7.0" python -m pytest --version >/dev/null 2>&1; then
  echo "SKIP: uv cannot resolve pytest>=7.0 (offline or no cache)"
  exit 77
fi

unset RUN_ALL_TIMEOUT_SECONDS PROBE_OUT
WRAPPER="$SCRIPT_CHECKOUT_ROOT/bin/lib/test-wrappers/pytest.py"
T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/fx" "$T/cwd"

# run_pytest <resdir> <fixture> <minVersion> — direct wrapper launch; rc in PRC and returned.
run_pytest() {
  local res="$1" fx="$2" mv="$3"
  mkdir -p "$res"
  PRC=0
  (
    cd "$T/cwd" || exit 2
    export RUN_ALL_RESULT_DIR RUN_ALL_RESULT_OWNER
    RUN_ALL_RESULT_DIR="$(np "$res")"
    RUN_ALL_RESULT_OWNER="$fx"
    run_with_timeout 120 uv run --no-project --with "pytest>=7.0" python "$(np "$WRAPPER")" "$(np "$fx")" "$mv" >"$res.out" 2>&1 </dev/null
  ) || PRC=$?
  return "$PRC"
}

# tsv_count <resdir> <STATE> — number of cases.tsv records in that state.
tsv_count() {
  if [ -f "$1/cases.tsv" ]; then awk -F'\t' -v s="$2" '$2==s{n++} END{print n+0}' "$1/cases.tsv"; else echo 0; fi
}

# tsv_has <resdir> <STATE> <case-substring> — a record in that state whose case contains the substring.
tsv_has() {
  [ -f "$1/cases.tsv" ] && awk -F'\t' -v s="$2" -v c="$3" '$2==s && index($3,c)>0{f=1} END{exit !f}' "$1/cases.tsv"
}

cat >"$T/fx/test_mixed.py" <<'EOF'
import pytest


def test_ok():
    assert True


def test_sk():
    pytest.skip("fixture")
EOF
cat >"$T/fx/test_allskip.py" <<'EOF'
import pytest


def test_a():
    pytest.skip("fixture")


@pytest.mark.skip(reason="fixture")
def test_b():
    assert False
EOF
printf '# no tests here\nX = 1\n' >"$T/fx/test_empty.py"
cat >"$T/fx/test_fail77.py" <<'EOF'
import pytest


@pytest.mark.parametrize("i", range(77))
def test_f(i):
    assert False
EOF
cat >"$T/fx/test_fail256.py" <<'EOF'
import pytest


@pytest.mark.parametrize("i", range(256))
def test_f(i):
    assert False
EOF
printf 'import no_such_module_2501_xyz\n\n\ndef test_never():\n    assert True\n' >"$T/fx/test_collect_err.py"
cat >"$T/fx/test_xfail.py" <<'EOF'
import pytest


def test_ok():
    assert True


@pytest.mark.xfail(reason="fixture")
def test_xf():
    assert False


@pytest.mark.xfail(reason="fixture")
def test_xp():
    assert True
EOF
cat >"$T/fx/test_env.py" <<'EOF'
import os


def test_env():
    val = "[" + os.environ.get("RUN_ALL_RESULT_DIR", "") + "|" + os.environ.get("RUN_ALL_RESULT_OWNER", "") + "]"
    with open(os.environ["PROBE_OUT"], "w") as fh:
        fh.write(val)
EOF

case_begin "wrapper-file-exists" "bin/lib/test-wrappers/pytest.py"
if [ -f "$WRAPPER" ]; then pass "pytest wrapper present"; else fail "pytest wrapper missing" "$WRAPPER"; fi
case_end

case_begin "pass-and-skip-exit-0-with-records" "bin/lib/test-wrappers/pytest.py"
run_pytest "$T/r-mixed" "$T/fx/test_mixed.py" 7.0
assert_eq "$PRC" 0
if tsv_has "$T/r-mixed" PASS test_ok; then pass "PASS record for test_ok"; else fail "PASS record for test_ok missing"; fi
if tsv_has "$T/r-mixed" SKIP test_sk; then pass "SKIP record for test_sk"; else fail "SKIP record for test_sk missing"; fi
mixed_native="$(np "$T/fx/test_mixed.py")"
if [ -f "$T/r-mixed/cases.tsv" ] && awk -F'\t' -v t="$mixed_native" '$4!=t{bad=1} END{exit (bad || NR==0)}' "$T/r-mixed/cases.tsv"; then
  pass "every record targets the wrapper path argument"
else
  fail "record target is not the path argument" "$mixed_native"
fi
case_end

case_begin "all-skipped-exit-77" "bin/lib/test-wrappers/pytest.py"
run_pytest "$T/r-allskip" "$T/fx/test_allskip.py" 7.0
assert_eq "$PRC" 77
assert_eq "$(tsv_count "$T/r-allskip" SKIP)" 2
case_end

case_begin "zero-tests-rc5-exit-77" "bin/lib/test-wrappers/pytest.py"
run_pytest "$T/r-empty" "$T/fx/test_empty.py" 7.0
assert_eq "$PRC" 77
assert_eq "$(tsv_count "$T/r-empty" PASS)" 0
case_end

case_begin "seventy-seven-failures-exit-1" "bin/lib/test-wrappers/pytest.py"
run_pytest "$T/r-f77" "$T/fx/test_fail77.py" 7.0
assert_eq "$PRC" 1
assert_eq "$(tsv_count "$T/r-f77" FAIL)" 77
case_end

case_begin "two-hundred-fifty-six-failures-exit-1" "bin/lib/test-wrappers/pytest.py"
run_pytest "$T/r-f256" "$T/fx/test_fail256.py" 7.0
assert_eq "$PRC" 1
assert_eq "$(tsv_count "$T/r-f256" FAIL)" 256
case_end

case_begin "collection-error-exit-1-with-fail-record" "bin/lib/test-wrappers/pytest.py"
run_pytest "$T/r-collect" "$T/fx/test_collect_err.py" 7.0
assert_eq "$PRC" 1
if [ "$(tsv_count "$T/r-collect" FAIL)" -ge 1 ]; then pass "collection error recorded as FAIL"; else fail "no FAIL record for collection error"; fi
case_end

case_begin "min-version-unmet-exit-79-with-marker" "bin/lib/test-wrappers/pytest.py"
run_pytest "$T/r-v99" "$T/fx/test_mixed.py" 99
assert_eq "$PRC" 79
if [ -f "$T/r-v99/unrunnable" ]; then
  assert_eq "$(tr -d '\r\n' <"$T/r-v99/unrunnable")" "pytest>=99"
else
  fail "unrunnable marker missing" "$T/r-v99/unrunnable"
fi
assert_eq "$(tsv_count "$T/r-v99" PASS)" 0
case_end

# An installed pytest whose own import breaks is a failure, never "runtime missing".
mkdir -p "$T/broken/pytest"
printf '%s\n' 'import no_such_dependency_2501' >"$T/broken/pytest/__init__.py"
case_begin "broken-pytest-install-is-fail-not-unrunnable" "bin/lib/test-wrappers/pytest.py"
PYTHONPATH="$(np "$T/broken")" run_pytest "$T/r-broken" "$T/fx/test_mixed.py" 7.0
assert_eq "broken install rc: $PRC" "broken install rc: 1"
if [ -e "$T/r-broken/unrunnable" ]; then fail "broken install wrote an unrunnable marker"; else pass "broken install: no unrunnable marker"; fi
if grep -q 'no_such_dependency_2501' "$T/r-broken.out"; then pass "broken install: the import error is shown"; else fail "import error not in output" "$(tail -3 "$T/r-broken.out")"; fi
case_end

# A pytest that cannot be found at all is the same FAIL: the install pre-fetches the package.
mkdir -p "$T/absent/pytest"
printf '%s\n' 'raise ModuleNotFoundError("No module named pytest (absent-2501)", name="pytest")' >"$T/absent/pytest/__init__.py"
case_begin "absent-pytest-is-fail-not-unrunnable" "bin/lib/test-wrappers/pytest.py"
PYTHONPATH="$(np "$T/absent")" run_pytest "$T/r-absent" "$T/fx/test_mixed.py" 7.0
assert_eq "absent pytest rc: $PRC" "absent pytest rc: 1"
if [ -e "$T/r-absent/unrunnable" ]; then fail "absent pytest wrote an unrunnable marker"; else pass "absent pytest: no unrunnable marker"; fi
if grep -q 'absent-2501' "$T/r-absent.out"; then pass "absent pytest: the import error is shown"; else fail "import error not in output" "$(tail -3 "$T/r-absent.out")"; fi
case_end

case_begin "xfail-and-xpass-recorded" "bin/lib/test-wrappers/pytest.py"
run_pytest "$T/r-xf" "$T/fx/test_xfail.py" 7.0
assert_eq "$PRC" 0
if tsv_has "$T/r-xf" XFAIL test_xf; then pass "XFAIL record for test_xf"; else fail "XFAIL record for test_xf missing"; fi
if tsv_has "$T/r-xf" XPASS test_xp; then pass "XPASS record for test_xp"; else fail "XPASS record for test_xp missing"; fi
if tsv_has "$T/r-xf" PASS test_ok; then pass "PASS record for test_ok"; else fail "PASS record for test_ok missing"; fi
case_end

case_begin "result-env-not-visible-to-test-code" "bin/lib/test-wrappers/pytest.py"
export PROBE_OUT
PROBE_OUT="$(np "$T/envprobe.txt")"
run_pytest "$T/r-env" "$T/fx/test_env.py" 7.0
unset PROBE_OUT
assert_eq "$PRC" 0
if [ -f "$T/envprobe.txt" ]; then
  assert_eq "$(tr -d '\r\n' <"$T/envprobe.txt")" "[|]"
else
  fail "env probe test did not run" "$T/envprobe.txt"
fi
case_end

# TIMEOUT is applied by the launcher, not the wrapper: one case through run_all_exec.
case_begin "launcher-timeout-env-gives-124" "bin/lib/test-wrappers/pytest.py"
mkdir -p "$T/to" "$T/r-to"
printf 'import time\n\n\ndef test_slow():\n    time.sleep(25)\n' >"$T/to/test_slow.py"
. "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-launch.sh"
RUN_ALL_EXEC_STATE=""
torc=0
export RUN_ALL_TIMEOUT_SECONDS=6
run_all_exec "$T/to/test_slow.py" "$T/to.out" "$T/to.err" "$T/r-to" || torc=$?
unset RUN_ALL_TIMEOUT_SECONDS
assert_eq "$torc" 124
assert_eq "${RUN_ALL_EXEC_STATE:-}" "TIMEOUT"
case_end

# Setup-stage reports (plan D4-2): a fixture that raises is a FAIL record (pytest "error"),
# a fixture that calls pytest.skip is a SKIP record — neither is dropped as "not a call stage".
cat >"$T/fx/test_setup_err.py" <<'EOF'
import pytest


@pytest.fixture
def broken():
    raise RuntimeError("fixture boom")


def test_ok():
    assert True


def test_uses_broken(broken):
    assert True
EOF
cat >"$T/fx/test_setup_skip.py" <<'EOF'
import pytest


@pytest.fixture
def skipper():
    pytest.skip("fixture skip")


def test_ok():
    assert True


def test_uses_skipper(skipper):
    assert True
EOF

case_begin "setup-stage-error-is-fail-exit-1" "bin/lib/test-wrappers/pytest.py"
run_pytest "$T/r-serr" "$T/fx/test_setup_err.py" 7.0
assert_eq "$PRC" 1
if tsv_has "$T/r-serr" FAIL test_uses_broken; then pass "FAIL record for the fixture error"; else fail "FAIL record for test_uses_broken missing"; fi
if tsv_has "$T/r-serr" PASS test_ok; then pass "PASS record for test_ok beside the fixture error"; else fail "PASS record for test_ok missing"; fi
case_end

case_begin "setup-stage-skip-is-skip-record" "bin/lib/test-wrappers/pytest.py"
run_pytest "$T/r-sskip" "$T/fx/test_setup_skip.py" 7.0
assert_eq "$PRC" 0
if tsv_has "$T/r-sskip" SKIP test_uses_skipper; then pass "SKIP record for the fixture skip"; else fail "SKIP record for test_uses_skipper missing"; fi
assert_eq "$(tsv_count "$T/r-sskip" FAIL)" 0
case_end

# Security round: one result per case. A teardown failure after a passing call reuses the test's
# seq (keyed by nodeid), so the readers, which keep the last record of a seq, see one FAIL.
cat >"$T/fx/test_teardown_err.py" <<'EOF'
import pytest


@pytest.fixture
def bad_teardown():
    yield
    raise RuntimeError("teardown boom")


def test_td(bad_teardown):
    assert True


def test_plain():
    assert True
EOF

# tsv_col <resdir> <column> <case-substring> — that column of the case's records, in file order.
tsv_col() {
  if [ -f "$1/cases.tsv" ]; then
    awk -F'\t' -v k="$2" -v c="$3" 'index($3,c)>0{printf "%s%s", (n++ ? " " : ""), $k}' "$1/cases.tsv"
  fi
}

case_begin "teardown-failure-reuses-the-case-seq" "bin/lib/test-wrappers/pytest.py"
run_pytest "$T/r-td" "$T/fx/test_teardown_err.py" 7.0
assert_eq "$PRC" 1
assert_eq "test_td states: $(tsv_col "$T/r-td" 2 test_td)" "test_td states: PASS FAIL"
td_seqs="$(tsv_col "$T/r-td" 1 test_td)"
if [ -n "$td_seqs" ] && [ "${td_seqs%% *}" = "${td_seqs##* }" ]; then
  pass "both test_td records carry one seq ($td_seqs)"
else
  fail "test_td records do not share a seq" "seqs=[$td_seqs]"
fi
case_end

case_begin "different-tests-get-different-seqs" "bin/lib/test-wrappers/pytest.py"
plain_seqs="$(tsv_col "$T/r-td" 1 test_plain)"
assert_eq "test_plain states: $(tsv_col "$T/r-td" 2 test_plain)" "test_plain states: PASS"
if [ -n "$plain_seqs" ] && [ -n "$td_seqs" ] && [ "$plain_seqs" != "${td_seqs%% *}" ]; then
  pass "test_plain has its own seq ($plain_seqs, test_td ${td_seqs%% *})"
else
  fail "test_plain shares test_td's seq" "plain=[$plain_seqs] td=[$td_seqs]"
fi
if [ -f "$T/r-td/cases.tsv" ]; then
  assert_eq "distinct seqs: $(cut -f1 "$T/r-td/cases.tsv" | sort -u | grep -c '')" "distinct seqs: 2"
else
  fail "cases.tsv missing" "$T/r-td/cases.tsv"
fi
case_end

# Security round: a relative test path that begins with '-' is a file, never a pytest option.
mkdir -p "$T/dash" "$T/r-dash"
printf 'def test_ok():\n    assert True\n' >"$T/dash/-t_dash.py"

case_begin "dash-leading-relative-path-is-a-file" "bin/lib/test-wrappers/pytest.py"
PRC=0
(
  cd "$T/dash" || exit 2
  export RUN_ALL_RESULT_DIR RUN_ALL_RESULT_OWNER
  RUN_ALL_RESULT_DIR="$(np "$T/r-dash")"
  RUN_ALL_RESULT_OWNER="-t_dash.py"
  run_with_timeout 120 uv run --no-project --with "pytest>=7.0" python "$(np "$WRAPPER")" "-t_dash.py" 7.0 >"$T/r-dash.out" 2>&1 </dev/null
) || PRC=$?
assert_eq "relative -t_dash.py rc: $PRC" "relative -t_dash.py rc: 0"
if tsv_has "$T/r-dash" PASS test_ok; then pass "PASS record for test_ok in -t_dash.py"; else fail "PASS record for -t_dash.py::test_ok missing" "$(head -c 300 "$T/r-dash.out" 2>/dev/null)"; fi
case_end

# Security round: pytest runs in a child that is never told the result directory, so test code can
# neither find it (module globals, argv, env) nor turn its own exit code into the wrapper's.
cat >"$T/fx/test_forge.py" <<'EOF'
import os
import sys
from pathlib import Path

import __main__


def test_forge():
    needle = "res-forge-2501"
    seen = [str(v) for v in vars(__main__).values()] + sys.argv + list(os.environ.values())
    with open(os.environ["PROBE_OUT"], "w") as fh:
        fh.write("leaked" if any(needle in s for s in seen) else "hidden")
    for arg in sys.argv[1:]:
        parent = Path(arg).parent
        if parent.is_dir():
            (parent / "unrunnable").write_text("pytest>=7.0\n")
    os._exit(79)
EOF
cat >"$T/fx/test_exit5.py" <<'EOF'
import os


def test_ok():
    assert True


def test_exit5():
    os._exit(5)
EOF

case_begin "test-code-cannot-forge-unrunnable" "bin/lib/test-wrappers/pytest.py"
export PROBE_OUT
PROBE_OUT="$(np "$T/forgeprobe.txt")"
run_pytest "$T/res-forge-2501" "$T/fx/test_forge.py" 7.0
unset PROBE_OUT
assert_eq "forge rc: $PRC" "forge rc: 1"
if [ -e "$T/res-forge-2501/unrunnable" ]; then fail "test code wrote an unrunnable marker"; else pass "forge: no unrunnable marker in the result dir"; fi
assert_eq "result dir: $(tr -d '\r\n' <"$T/forgeprobe.txt" 2>/dev/null)" "result dir: hidden"
case_end

case_begin "child-exit-5-after-a-record-is-fail-not-skip" "bin/lib/test-wrappers/pytest.py"
run_pytest "$T/r-exit5" "$T/fx/test_exit5.py" 7.0
assert_eq "exit5 rc: $PRC" "exit5 rc: 1"
if tsv_has "$T/r-exit5" PASS test_ok; then pass "exit5: the earlier PASS record is kept"; else fail "exit5: PASS record for test_ok missing"; fi
case_end

# pytest's own "no tests collected" is rc 5 too; only pytest ending the session may turn it into a skip.
cat >"$T/fx/test_exit5_first.py" <<'EOF'
import os


def test_exit5_first():
    os._exit(5)
EOF
case_begin "child-exit-5-before-any-record-is-fail-not-skip" "bin/lib/test-wrappers/pytest.py"
run_pytest "$T/r-exit5-first" "$T/fx/test_exit5_first.py" 7.0
assert_eq "exit5-first rc: $PRC" "exit5-first rc: 1"
if [ -s "$T/r-exit5-first/cases.tsv" ]; then fail "exit5-first: a case record was written"; else pass "exit5-first: no case record, so the rc alone decided"; fi
case_end

# `uv run` picks the interpreter and the registry pins pytest only, so the wrapper keeps to what
# Python 3.8 has: 3.8 grammar, annotations never evaluated, no write_text(newline=) (3.10).
cat >"$T/floor.py" <<'EOF'
import ast
import sys

tree = ast.parse(open(sys.argv[1], encoding="utf-8").read(), feature_version=(3, 8))
future = any(
    isinstance(n, ast.ImportFrom) and n.module == "__future__" and any(a.name == "annotations" for a in n.names)
    for n in tree.body
)
late = sorted(
    {
        f"{n.func.attr}({kw.arg}=)"
        for n in ast.walk(tree)
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr in ("write_text", "read_text")
        for kw in n.keywords
        if kw.arg == "newline"
    }
)
print(f"grammar=3.8 future-annotations={future} newer-keywords={late}")
EOF
case_begin "wrapper-keeps-to-python-3-8" "bin/lib/test-wrappers/pytest.py"
floor_got="$(run_with_timeout 90 uv run --no-project python "$(np "$T/floor.py")" "$(np "$WRAPPER")" 2>&1 | tr -d '\r')"
assert_eq "floor: $floor_got" "floor: grammar=3.8 future-annotations=True newer-keywords=[]"
case_end

echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
