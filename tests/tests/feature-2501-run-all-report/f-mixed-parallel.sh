#!/usr/bin/env bash
# f-mixed-parallel.sh — real pytest and node:test files side by side under -j 4 (#2501).
# Tests: tests/run-all.sh, bin/lib/run-all-launch.sh, bin/lib/run-all-report.sh, bin/lib/test-wrappers/pytest.py, bin/lib/test-wrappers/node.js
# Tags: tests, bin, run-all, report, pytest, node, parallel, scope:issue-specific

# WHY: every other real-wrapper run is -j 1, so a result directory shared between two files that run
# at once (case records of one file printed under another, or a wrong tally) would go unseen.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_fx.sh"
# shellcheck source=../../lib/harness.sh
. "$FX_REPO_ROOT/tests/lib/harness.sh"

command -v uv >/dev/null 2>&1 || { echo "SKIP: uv not on PATH"; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 77; }

fx_init "f-mixed-parallel"
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
export WORKFLOW_STATE_DIR="$FX_TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
rr_require_report

R="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }

# Overlap barrier: each file holds a run.<name> marker for as long as it runs; seeing a marker of the
# other language leaves saw.<name>. It keeps waiting (the seconds in <overlap>/limit at most) until both
# languages have a saw.*, so neither side leaves before the other has seen it. All four files start
# together under -j 4, so pytest and node:test must meet; a sequential run leaves no saw.*.
OV="$FX_TMP_ROOT/overlap"
mkdir -p "$OV"
printf '20' >"$OV/limit"
OVN="$OV"
if command -v cygpath >/dev/null 2>&1; then OVN="$(cygpath -m "$OV")"; fi
cat >"$FX_TMP_ROOT/barrier.py" <<EOF
import atexit, os, time
_D = "$OVN"
_N = os.path.basename(__file__)
open(os.path.join(_D, "run." + _N), "w").close()
atexit.register(lambda: os.path.exists(os.path.join(_D, "run." + _N)) and os.remove(os.path.join(_D, "run." + _N)))
_end = time.time() + float(open(os.path.join(_D, "limit")).read())
while time.time() < _end:
    if [n for n in os.listdir(_D) if n.startswith("run.") and not n.endswith(".py")]:
        open(os.path.join(_D, "saw." + _N), "w").close()
    _saw = [n for n in os.listdir(_D) if n.startswith("saw.")]
    if [n for n in _saw if n.endswith(".py")] and [n for n in _saw if not n.endswith(".py")]:
        break
    time.sleep(0.05)


EOF
cat >"$FX_TMP_ROOT/barrier.js" <<EOF
const fs = require("fs");
const path = require("path");
const ovDir = "$OVN";
const ovName = path.basename(__filename);
fs.writeFileSync(path.join(ovDir, "run." + ovName), "");
process.on("exit", () => { try { fs.unlinkSync(path.join(ovDir, "run." + ovName)); } catch (e) { /* gone */ } });
for (const end = Date.now() + 1000 * Number(fs.readFileSync(path.join(ovDir, "limit"), "utf8")); Date.now() < end;) {
  if (fs.readdirSync(ovDir).some((n) => n.startsWith("run.") && !n.endsWith(".js"))) {
    fs.writeFileSync(path.join(ovDir, "saw." + ovName), "");
  }
  const saw = fs.readdirSync(ovDir).filter((n) => n.startsWith("saw."));
  if (saw.some((n) => n.endsWith(".js")) && saw.some((n) => !n.endsWith(".js"))) break;
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
}
EOF
# fx_file <name> <barrier> <line>... — a fixture test file: the barrier, then its own lines.
fx_file() {
    local name="$1" barrier="$2"
    shift 2
    cat "$FX_TMP_ROOT/$barrier" >"$R/tests/bin/$name"
    printf '%s\n' "$@" >>"$R/tests/bin/$name"
}
fx_file test_par_a.py barrier.py 'def test_py_a_ok():' '    assert True'
fx_file test_par_b.py barrier.py 'def test_py_b_ok():' '    assert True' '' '' 'def test_py_b_ng():' '    assert 1 == 2'
fx_file par_a.test.js barrier.js 'const test = require("node:test");' 'test("node-a-ok", () => {});'
fx_file par_b.test.js barrier.js 'const test = require("node:test");' 'const assert = require("assert");' \
    'test("node-b-ok", () => {});' 'test("node-b-ng", () => { assert.strictEqual(1, 2); });'
O="$FX_TMP_ROOT/par.out"
rr_exec "$R" 240 "$O" "$FX_TMP_ROOT/par.err" -j 4 --all; RC=$?

# case_lines <out> — the per-case record lines, sorted (their print order follows completion order).
case_lines() { grep -E '^(PASS|FAIL|SKIP|XFAIL|XPASS) [^:]*::' "$1" | LC_ALL=C sort; }

# one_case <state> <file-regex> <case> — exactly one case line, and its target is its own file.
one_case() {
    [ "$(grep -cE "^$1 .*$2::.*$3 target=.*$2\$" "$O")" = "1" ] && [ "$(grep -cE "::.*$3 target=" "$O")" = "1" ]
}

case_begin "parallel-pytest-and-node-keep-their-own-case-records" "tests/run-all.sh"
[ "$RC" -eq 1 ]
fx_check $? "F1. two failing files of four under -j 4: runner exit 1 (rc=$RC)"
one_case PASS 'test_par_a\.py' test_py_a_ok && one_case PASS 'test_par_b\.py' test_py_b_ok && one_case FAIL 'test_par_b\.py' test_py_b_ng
fx_check $? "F2. each pytest case is printed once, under its own file"
one_case PASS 'par_a\.test\.js' node-a-ok && one_case PASS 'par_b\.test\.js' node-b-ok && one_case FAIL 'par_b\.test\.js' node-b-ng
fx_check $? "F3. each node case is printed once, under its own file"
[ "$(grep -cE '^(PASS|FAIL|SKIP|XFAIL|XPASS) [^:]*::' "$O")" = "6" ] && ! grep -qE '::\(file\) ' "$O"
fx_check $? "F4. exactly the six wrapper records are printed, no synthetic (file) line"
[ "$(grep -cE '^PASS: .*(test_par_a\.py|par_a\.test\.js)$' "$O")" = "2" ] &&
    [ "$(grep -cE '^FAIL: .*(test_par_b\.py|par_b\.test\.js) \(exit 1\)$' "$O")" = "2" ]
fx_check $? "F5. file-level lines: two PASS, two FAIL (exit 1)"
[ "$(rr_contract_rest "$O")" = "PASS=2 FAIL=2 SKIP=0 EXECUTED=4 UNRUNNABLE=0 TIMEOUT=0" ] && [ "$(fx_count_contract "$O")" = "1" ]
fx_check $? "F6. contract: PASS=2 FAIL=2 SKIP=0 EXECUTED=4 UNRUNNABLE=0 TIMEOUT=0 (got <<$(rr_contract_rest "$O")>>)"
case_end

case_begin "parallel-run-really-overlaps" "tests/run-all.sh"
SAW_PY="$(find "$OV" -name 'saw.*.py' 2>/dev/null | wc -l | tr -d ' ')"
SAW_JS="$(find "$OV" -name 'saw.*.js' 2>/dev/null | wc -l | tr -d ' ')"
[ "$SAW_PY" -ge 1 ] && [ "$SAW_JS" -ge 1 ]
fx_check $? "F7. a pytest file saw a node:test file running beside it, and the reverse (py=$SAW_PY js=$SAW_JS)"
[ "$(find "$OV" -name 'run.*' 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
fx_check $? "F8. every file removed its run marker when it ended"
case_end

# Control: the same four files under -j 1 leave no saw marker, so F7 is not satisfied by any run.
rm -f "$OV"/saw.* "$OV"/run.*
printf '2' >"$OV/limit"
rr_exec "$R" 240 "$FX_TMP_ROOT/seq.out" "$FX_TMP_ROOT/seq.err" -j 1 --all; SEQ_RC=$?
case_begin "sequential-run-leaves-no-overlap-marker" "tests/run-all.sh"
[ "$SEQ_RC" -eq 1 ] && [ "$(find "$OV" -name 'saw.*' 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
fx_check $? "F9. -j 1: runner exit 1 and no saw marker (rc=$SEQ_RC)"
case_end

# A second run of the same root repeats the first: no stale or doubled record survives between runs.
case_begin "rerun-repeats-the-same-records" "tests/run-all.sh"
[ -n "$(case_lines "$O")" ] && [ "$(case_lines "$O")" = "$(case_lines "$FX_TMP_ROOT/seq.out")" ]
fx_check $? "F10. the sequential rerun prints the same six case lines as the parallel run"
[ "$(rr_contract_rest "$FX_TMP_ROOT/seq.out")" = "$(rr_contract_rest "$O")" ] && [ "$(fx_count_contract "$FX_TMP_ROOT/seq.out")" = "1" ]
fx_check $? "F11. the rerun's contract equals the first run's (got <<$(rr_contract_rest "$FX_TMP_ROOT/seq.out")>>)"
case_end

[ "$FX_ERRORS" -eq 0 ] || { fx_show_tail "$O" 30; fx_show_tail "$FX_TMP_ROOT/par.err" 20; }
fx_finish
