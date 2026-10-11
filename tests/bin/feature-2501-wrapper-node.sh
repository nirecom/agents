#!/usr/bin/env bash
# tests/bin/feature-2501-wrapper-node.sh
# Tests: bin/lib/test-wrappers/node.js, bin/lib/test-wrappers/node-reporter.mjs
# Tags: scope:issue-specific, test-language-wrapper, node, node-test, run-all, result-dir, unrunnable, tl2
# Node language wrapper (#2501 D4-3, single run): plain-script passthrough (0 / 77 / other -> 1,
# no records), node:test exit table (run-time loads too), malformed record -> FAIL, reporter excludes
# suite events and joins nesting with '>', version floor -> 79 + marker, env removal, synthetic FAIL.
# Which path a file takes (guard marker, not source text): feature-2501-wrapper-node-guard.sh.
set -u

# Pin to this checkout: the wrappers under test are the ones beside this file.
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$SCRIPT_CHECKOUT_ROOT"
. "$REPO_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 77; }

unset RUN_ALL_TIMEOUT_SECONDS PROBE_OUT RUN_ALL_NODE_CASES
WRAPPER="$SCRIPT_CHECKOUT_ROOT/bin/lib/test-wrappers/node.js"
REPORTER="$SCRIPT_CHECKOUT_ROOT/bin/lib/test-wrappers/node-reporter.mjs"
T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/fx" "$T/cwd"

# run_node <resdir> <fixture> <minVersion> — direct wrapper launch; rc in PRC and returned.
run_node() {
  local res="$1" fx="$2" mv="$3"
  mkdir -p "$res"
  PRC=0
  (
    cd "$T/cwd" || exit 2
    export RUN_ALL_RESULT_DIR RUN_ALL_RESULT_OWNER
    RUN_ALL_RESULT_DIR="$(np "$res")"
    RUN_ALL_RESULT_OWNER="$fx"
    run_with_timeout 120 node "$(np "$WRAPPER")" "$(np "$fx")" "$mv" >"$res.out" 2>&1 </dev/null
  ) || PRC=$?
  return "$PRC"
}

# tsv_count <resdir> <STATE> — number of cases.tsv records in that state.
tsv_count() {
  if [ -f "$1/cases.tsv" ]; then awk -F'\t' -v s="$2" '$2==s{n++} END{print n+0}' "$1/cases.tsv"; else echo 0; fi
}

# tsv_total <resdir> — number of cases.tsv records of any state (0 when absent).
tsv_total() {
  if [ -f "$1/cases.tsv" ]; then awk 'NF{n++} END{print n+0}' "$1/cases.tsv"; else echo 0; fi
}

# tsv_has <resdir> <STATE> <case> — a record in that state with exactly that case name.
tsv_has() {
  [ -f "$1/cases.tsv" ] && awk -F'\t' -v s="$2" -v c="$3" '$2==s && $3==c{f=1} END{exit !f}' "$1/cases.tsv"
}

cat >"$T/fx/req.js" <<'EOF'
const test = require("node:test");
test("req-ok", () => {});
EOF
cat >"$T/fx/imp.mjs" <<'EOF'
import test from 'node:test';
test('imp-ok', () => {});
EOF
printf 'process.exit(0);\n' >"$T/fx/plain0.js"
printf 'process.exit(77);\n' >"$T/fx/plain77.js"
printf 'process.exit(3);\n' >"$T/fx/plain3.js"
: >"$T/fx/plainempty.js"
printf 'const test = require("node:test");\n' >"$T/fx/zero.js"
cat >"$T/fx/mixed.js" <<'EOF'
const test = require("node:test");
test("ok", () => {});
test.skip("sk", () => {});
EOF
cat >"$T/fx/allskip.js" <<'EOF'
const test = require("node:test");
test.skip("a", () => {});
test("b", (t) => { t.skip("fixture"); });
EOF
cat >"$T/fx/fail77.js" <<'EOF'
const test = require("node:test");
for (let i = 0; i < 77; i++) test(`f${i}`, () => { throw new Error("fixture"); });
EOF
cat >"$T/fx/fail256.js" <<'EOF'
const test = require("node:test");
for (let i = 0; i < 256; i++) test(`f${i}`, () => { throw new Error("fixture"); });
EOF
cat >"$T/fx/nested.js" <<'EOF'
const { describe, it } = require("node:test");
describe("outer", () => { it("inner", () => {}); });
EOF
cat >"$T/fx/envtest.js" <<'EOF'
const test = require("node:test");
const fs = require("fs");
test("env", () => {
  const e = process.env;
  fs.writeFileSync(e.PROBE_OUT, "[" + (e.RUN_ALL_RESULT_DIR || "") + "|" + (e.RUN_ALL_RESULT_OWNER || "") + "]");
});
EOF
cat >"$T/fx/envplain.js" <<'EOF'
const e = process.env;
require("fs").writeFileSync(e.PROBE_OUT, "[" + (e.RUN_ALL_RESULT_DIR || "") + "|" + (e.RUN_ALL_RESULT_OWNER || "") + "]");
EOF
cat >"$T/fx/badexit.js" <<'EOF'
// a node:test file (it imports node:test) that exits 3 without any test failing
require("node:test");
process.exit(3);
EOF

case_begin "wrapper-and-reporter-files-exist" "bin/lib/test-wrappers/node.js"
if [ -f "$WRAPPER" ]; then pass "node wrapper present"; else fail "node wrapper missing" "$WRAPPER"; fi
if [ -f "$REPORTER" ]; then pass "node reporter present"; else fail "node reporter missing" "$REPORTER"; fi
case_end

case_begin "require-node-test-writes-case-records" "bin/lib/test-wrappers/node-reporter.mjs"
run_node "$T/r-req" "$T/fx/req.js" 20.0
assert_eq "$PRC" 0
if tsv_has "$T/r-req" PASS req-ok; then pass "require form -> PASS record"; else fail "require form wrote no PASS record for req-ok"; fi
case_end

case_begin "import-node-test-writes-case-records" "bin/lib/test-wrappers/node-reporter.mjs"
run_node "$T/r-imp" "$T/fx/imp.mjs" 20.0
assert_eq "$PRC" 0
if tsv_has "$T/r-imp" PASS imp-ok; then pass "import form -> PASS record"; else fail "import form wrote no PASS record for imp-ok"; fi
case_end

case_begin "plain-script-passthrough-exit-codes" "bin/lib/test-wrappers/node.js"
run_node "$T/r-p0" "$T/fx/plain0.js" 20.0
assert_eq "$PRC" 0
run_node "$T/r-p77" "$T/fx/plain77.js" 20.0
assert_eq "$PRC" 77
run_node "$T/r-p3" "$T/fx/plain3.js" 20.0
assert_eq "$PRC" 1
run_node "$T/r-pe" "$T/fx/plainempty.js" 20.0
assert_eq "$PRC" 0
assert_eq "$(tsv_total "$T/r-p0")$(tsv_total "$T/r-p77")$(tsv_total "$T/r-p3")$(tsv_total "$T/r-pe")" "0000"
case_end

case_begin "node-test-zero-tests-exit-77" "bin/lib/test-wrappers/node.js"
run_node "$T/r-zero" "$T/fx/zero.js" 20.0
assert_eq "$PRC" 77
case_end

case_begin "pass-and-skip-exit-0-with-records" "bin/lib/test-wrappers/node-reporter.mjs"
run_node "$T/r-mixed" "$T/fx/mixed.js" 20.0
assert_eq "$PRC" 0
if tsv_has "$T/r-mixed" PASS ok; then pass "PASS record for ok"; else fail "PASS record for ok missing"; fi
if tsv_has "$T/r-mixed" SKIP sk; then pass "SKIP record for sk"; else fail "SKIP record for sk missing"; fi
case_end

case_begin "all-skipped-exit-77" "bin/lib/test-wrappers/node.js"
run_node "$T/r-allskip" "$T/fx/allskip.js" 20.0
assert_eq "$PRC" 77
assert_eq "$(tsv_count "$T/r-allskip" SKIP)" 2
case_end

case_begin "seventy-seven-failures-exit-1" "bin/lib/test-wrappers/node.js"
run_node "$T/r-f77" "$T/fx/fail77.js" 20.0
assert_eq "$PRC" 1
assert_eq "$(tsv_count "$T/r-f77" FAIL)" 77
case_end

case_begin "two-hundred-fifty-six-failures-exit-1" "bin/lib/test-wrappers/node.js"
run_node "$T/r-f256" "$T/fx/fail256.js" 20.0
assert_eq "$PRC" 1
assert_eq "$(tsv_count "$T/r-f256" FAIL)" 256
case_end

# Plan D4-3 says nesting joins parent names with '>'; surrounding spaces are not pinned, so tolerated.
case_begin "suite-events-excluded-nesting-joined" "bin/lib/test-wrappers/node-reporter.mjs"
run_node "$T/r-nest" "$T/fx/nested.js" 20.0
assert_eq "$PRC" 0
if [ -f "$T/r-nest/cases.tsv" ] && awk -F'\t' '$2=="PASS" && $3 ~ /^outer *> *inner$/{f=1} END{exit !f}' "$T/r-nest/cases.tsv"; then
  pass "nested case recorded as outer > inner"
else
  fail "nested case record outer>inner missing"
fi
if [ -f "$T/r-nest/cases.tsv" ] && ! awk -F'\t' '$3=="outer"{f=1} END{exit !f}' "$T/r-nest/cases.tsv"; then
  pass "describe suite event not recorded"
else
  fail "suite 'outer' recorded as a case (or no cases.tsv)"
fi
assert_eq "$(tsv_total "$T/r-nest")" 1
case_end

# Sibling suites that run at the same time, the later-declared one finishing first: each case
# must still be named under its own suite.
cat >"$T/fx/concurrent.js" <<'EOF'
const { describe, it } = require("node:test");
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
describe("root", { concurrency: true }, () => {
  describe("slow", { concurrency: true }, () => {
    it("s1", async () => { await wait(400); });
    it("s2", async () => { await wait(50); });
  });
  describe("fast", { concurrency: true }, () => {
    it("f1", async () => { await wait(10); });
    it("f2", () => {});
  });
});
EOF
case_begin "concurrent-sibling-suites-keep-their-own-parents" "bin/lib/test-wrappers/node-reporter.mjs"
run_node "$T/r-conc" "$T/fx/concurrent.js" 20.0
assert_eq "concurrent: rc=$PRC total=$(tsv_total "$T/r-conc")" "concurrent: rc=0 total=4"
while IFS= read -r conc_name; do
  if tsv_has "$T/r-conc" PASS "$conc_name"; then pass "concurrent: PASS record [$conc_name]"; else fail "concurrent: PASS record [$conc_name] missing" "$(cut -f3 "$T/r-conc/cases.tsv" 2>/dev/null | tr '\n' ';')"; fi
done <<'ROWS'
root > slow > s1
root > slow > s2
root > fast > f1
root > fast > f2
ROWS
case_end

# The reporter fed an event stream directly: a result arriving after a sibling suite has started
# cannot be produced with a real node run, which reports in declaration order.
cat >"$T/feed.mjs" <<'EOF'
import { pathToFileURL } from "node:url";
const { default: reporter } = await import(pathToFileURL(process.argv[2]).href);
const head = [["start", 0, "root"], ["start", 1, "slow"], ["start", 2, "s1"]];
const streams = {
  ordered: [...head, ["pass", 2, "s1"], ["pass", 1, "slow", 1], ["start", 1, "fast"], ["start", 2, "f1"], ["pass", 2, "f1"]],
  interleaved: [...head, ["start", 1, "fast"], ["start", 2, "f1"], ["pass", 2, "s1"], ["pass", 2, "f1"]],
};
async function* source() {
  for (const [type, nesting, name, suite] of streams[process.argv[3]]) {
    yield { type: `test:${type}`, data: { name, nesting, details: suite ? { type: "suite" } : {} } };
  }
}
const got = [];
for await (const line of reporter(source())) got.push(line.split("\t").slice(1, 3).join(" "));
console.log(`records=${got.join(";")} exit=${process.exitCode ?? 0}`);
process.exitCode = 0;
EOF
case_begin "out-of-order-result-is-a-bare-fail-not-a-borrowed-parent" "bin/lib/test-wrappers/node-reporter.mjs"
while IFS='|' read -r feed_name feed_want; do
  feed_got="$(run_with_timeout 60 node "$(np "$T/feed.mjs")" "$(np "$REPORTER")" "$feed_name" 2>/dev/null | tr -d '\r' | tail -n 1)"
  assert_eq "feed $feed_name: $feed_got" "feed $feed_name: $feed_want"
done <<'ROWS'
ordered|records=PASS root > slow > s1;PASS root > fast > f1 exit=0
interleaved|records=FAIL s1;PASS root > fast > f1 exit=1
ROWS
case_end

case_begin "min-version-unmet-exit-79-with-marker" "bin/lib/test-wrappers/node.js"
run_node "$T/r-v99" "$T/fx/mixed.js" 99.0
assert_eq "$PRC" 79
if [ -f "$T/r-v99/unrunnable" ]; then
  assert_eq "$(tr -d '\r\n' <"$T/r-v99/unrunnable")" "node>=99.0"
else
  fail "unrunnable marker missing" "$T/r-v99/unrunnable"
fi
assert_eq "$(tsv_total "$T/r-v99")" 0
case_end

case_begin "result-env-removed-before-child" "bin/lib/test-wrappers/node.js"
export PROBE_OUT
PROBE_OUT="$(np "$T/env-test.txt")"
run_node "$T/r-envt" "$T/fx/envtest.js" 20.0
assert_eq "$PRC" 0
PROBE_OUT="$(np "$T/env-plain.txt")"
run_node "$T/r-envp" "$T/fx/envplain.js" 20.0
assert_eq "$PRC" 0
unset PROBE_OUT
for probe in env-test env-plain; do
  if [ -f "$T/$probe.txt" ]; then
    assert_eq "$(tr -d '\r\n' <"$T/$probe.txt")" "[|]"
  else
    fail "$probe probe did not run"
  fi
done
case_end

# Plan D4-3: child rc != 0 with no FAIL record from the reporter -> synthetic FAIL (file).
# The reporter may itself report a file-level failure, so either FAIL source satisfies rc 1 + FAIL>=1.
case_begin "nonzero-child-without-fail-record-gets-fail" "bin/lib/test-wrappers/node.js"
run_node "$T/r-bad" "$T/fx/badexit.js" 20.0
assert_eq "$PRC" 1
if [ "$(tsv_count "$T/r-bad" FAIL)" -ge 1 ]; then pass "FAIL record present for non-zero child"; else fail "no FAIL record for non-zero child"; fi
case_end

# TIMEOUT is applied by the launcher (js entry becomes supported), not the wrapper.
case_begin "launcher-timeout-env-gives-124" "bin/lib/test-wrappers/node.js"
mkdir -p "$T/to" "$T/r-to"
printf 'setTimeout(() => {}, 25000);\n' >"$T/to/slow.js"
. "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-launch.sh"
RUN_ALL_EXEC_STATE=""
torc=0
export RUN_ALL_TIMEOUT_SECONDS=5
run_all_exec "$T/to/slow.js" "$T/to.out" "$T/to.err" "$T/r-to" || torc=$?
unset RUN_ALL_TIMEOUT_SECONDS
assert_eq "$torc" 124
assert_eq "${RUN_ALL_EXEC_STATE:-}" "TIMEOUT"
case_end

# Security round: the reporter's own channel (RUN_ALL_NODE_CASES) is result-dir access too, so
# node:test code must not see it any more than RUN_ALL_RESULT_DIR / _OWNER.
cat >"$T/fx/envcases.js" <<'EOF'
const test = require("node:test");
const fs = require("fs");
test("envcases", () => {
  const e = process.env;
  fs.writeFileSync(e.PROBE_OUT, "[" + (e.RUN_ALL_NODE_CASES || "") + "|" + (e.RUN_ALL_RESULT_DIR || "") + "|" + (e.RUN_ALL_RESULT_OWNER || "") + "]");
});
EOF

case_begin "node-test-code-sees-no-result-channel" "bin/lib/test-wrappers/node.js"
export PROBE_OUT
PROBE_OUT="$(np "$T/env-cases.txt")"
run_node "$T/r-envc" "$T/fx/envcases.js" 20.0
unset PROBE_OUT
assert_eq "$PRC" 0
if [ -f "$T/env-cases.txt" ]; then
  assert_eq "$(tr -d '\r\n' <"$T/env-cases.txt")" "[||]"
else
  fail "envcases probe did not run"
fi
if tsv_has "$T/r-envc" PASS envcases; then pass "reporter still records envcases as PASS"; else fail "PASS record for envcases missing"; fi
case_end

# Security round: a relative test path that begins with '-' is a file, never a node option.
mkdir -p "$T/dash"
printf 'process.exit(0);\n' >"$T/dash/-dash0.js"
cat >"$T/dash/-dash-t.js" <<'EOF'
const test = require("node:test");
test("dash-ok", () => {});
EOF
# run_node_rel <resdir> <relative-fixture> — the wrapper launched from $T/dash with a relative path.
run_node_rel() {
  local res="$1" fx="$2"
  mkdir -p "$res"
  PRC=0
  (
    cd "$T/dash" || exit 2
    export RUN_ALL_RESULT_DIR RUN_ALL_RESULT_OWNER
    RUN_ALL_RESULT_DIR="$(np "$res")"
    RUN_ALL_RESULT_OWNER="$fx"
    run_with_timeout 120 node "$(np "$WRAPPER")" "$fx" 20.0 >"$res.out" 2>&1 </dev/null
  ) || PRC=$?
  return "$PRC"
}

case_begin "dash-leading-relative-path-is-a-file" "bin/lib/test-wrappers/node.js"
run_node_rel "$T/r-dash0" "-dash0.js"
assert_eq "plain -dash0.js rc: $PRC" "plain -dash0.js rc: 0"
run_node_rel "$T/r-dasht" "-dash-t.js"
assert_eq "node:test -dash-t.js rc: $PRC" "node:test -dash-t.js rc: 0"
if tsv_has "$T/r-dasht" PASS dash-ok; then pass "PASS record for dash-ok"; else fail "PASS record for dash-ok missing" "$(head -c 300 "$T/r-dasht.out" 2>/dev/null)"; fi
case_end

# Plan D4-3 (reporter-silent variant): every test passes, so the reporter records no FAIL, yet the
# child exits 3 -> the wrapper's own synthetic "(file)" FAIL record, and exit 1.
cat >"$T/fx/exitcode3.js" <<'EOF'
const test = require("node:test");
test("ok-ec3", () => {});
process.exitCode = 3;
EOF
case_begin "nonzero-child-with-passing-tests-gets-synthetic-file-fail" "bin/lib/test-wrappers/node.js"
run_node "$T/r-ec3" "$T/fx/exitcode3.js" 20.0
assert_eq "exitCode 3: rc=$PRC" "exitCode 3: rc=1"
if tsv_has "$T/r-ec3" PASS ok-ec3; then pass "exitCode 3: reporter PASS record for ok-ec3"; else fail "exitCode 3: PASS record for ok-ec3 missing"; fi
assert_eq "exitCode 3: FAIL records=$(tsv_count "$T/r-ec3" FAIL)" "exitCode 3: FAIL records=1"
ec3_syn="$(awk -F'\t' '$2=="FAIL" && $3=="(file)" {print $4}' "$T/r-ec3/cases.tsv" 2>/dev/null)"
assert_eq "exitCode 3: synthetic (file) FAIL owner=$ec3_syn" "exitCode 3: synthetic (file) FAIL owner=$(np "$T/fx/exitcode3.js")"
case_end

# Security round: a file that loads node:test at run time (here through a helper module) is a
# node:test file too — same records, same exit table, and still no route to the result directory.
printf '%s\n' 'module.exports = require("node:test");' >"$T/fx/rt-helper.js"
cat >"$T/fx/rt-mixed.js" <<'EOF'
const test = require("./rt-helper.js");
test("rt-ok", () => {});
test("rt-sk", { skip: true }, () => {});
EOF
cat >"$T/fx/rt-fail.js" <<'EOF'
const test = require("./rt-helper.js");
test("rt-ok", () => {});
test("rt-bad", () => { throw new Error("fixture"); });
EOF
printf '%s\n' 'const test = require("./rt-helper.js");' 'test("rt-late", () => {});' 'process.exit(3);' >"$T/fx/rt-exit3.js"
cat >"$T/fx/rt-probe.js" <<'EOF'
const test = require("./rt-helper.js");
const e = process.env;
const seen = [e.RUN_ALL_RESULT_DIR, e.RUN_ALL_RESULT_OWNER, e.RUN_ALL_NODE_GUARD_MARKER].map((v) => v || "").join("|");
const inArgv = process.execArgv.join(" ").includes(e.PROBE_RESDIR) ? "argv-leak" : "argv-clean";
require("fs").writeFileSync(e.PROBE_OUT, "[" + seen + "|" + inArgv + "]");
test("rt-probe", () => {});
EOF

case_begin "run-time-node-test-load-uses-node-test-exit-table" "bin/lib/test-wrappers/node.js"
run_node "$T/r-rtm" "$T/fx/rt-mixed.js" 20.0
assert_eq "rt-mixed: rc=$PRC pass=$(tsv_count "$T/r-rtm" PASS) skip=$(tsv_count "$T/r-rtm" SKIP) total=$(tsv_total "$T/r-rtm")" "rt-mixed: rc=0 pass=1 skip=1 total=2"
rtm_owner="$(awk -F'\t' '$3=="rt-ok" {print $4}' "$T/r-rtm/cases.tsv" 2>/dev/null)"
assert_eq "rt-mixed: owner=$rtm_owner" "rt-mixed: owner=$(np "$T/fx/rt-mixed.js")"
run_node "$T/r-rtf" "$T/fx/rt-fail.js" 20.0
assert_eq "rt-fail: rc=$PRC pass=$(tsv_count "$T/r-rtf" PASS) fail=$(tsv_count "$T/r-rtf" FAIL)" "rt-fail: rc=1 pass=1 fail=1"
if tsv_has "$T/r-rtf" FAIL rt-bad; then pass "rt-fail: FAIL record for rt-bad"; else fail "rt-fail: FAIL record for rt-bad missing"; fi
run_node "$T/r-rt3" "$T/fx/rt-exit3.js" 20.0
assert_eq "rt-exit3: rc=$PRC fail=$(tsv_count "$T/r-rt3" FAIL)" "rt-exit3: rc=1 fail=1"
if tsv_has "$T/r-rt3" FAIL "(file)"; then pass "rt-exit3: synthetic (file) FAIL"; else fail "rt-exit3: synthetic (file) FAIL missing"; fi
case_end

case_begin "run-time-node-test-code-sees-no-result-channel" "bin/lib/test-wrappers/node.js"
export PROBE_OUT PROBE_RESDIR
PROBE_OUT="$(np "$T/rt-probe.txt")"
PROBE_RESDIR="$(np "$T/r-rtp")"
run_node "$T/r-rtp" "$T/fx/rt-probe.js" 20.0
unset PROBE_OUT PROBE_RESDIR
assert_eq "rt-probe: rc=$PRC" "rt-probe: rc=0"
assert_eq "rt-probe: $(tr -d '\r\n' <"$T/rt-probe.txt" 2>/dev/null)" "rt-probe: [|||argv-clean]"
if tsv_has "$T/r-rtp" PASS rt-probe; then pass "rt-probe: PASS record"; else fail "rt-probe: PASS record missing"; fi
case_end

# Security round (D4-3): test code can find the reporter's scratch destination in execArgv and append
# to it. A malformed line makes the file FAIL; a forged well-formed PASS line cannot hide a real FAIL.
cat >"$T/fx/forge.js" <<'EOF'
const test = require("node:test");
const fs = require("fs");
const arg = process.execArgv.find((a) => a.startsWith("--test-reporter-destination="));
const dest = arg ? arg.slice("--test-reporter-destination=".length) : "";
test("forge", () => {
  if (!dest) return;
  if (process.env.FORGE_MODE === "malformed") fs.appendFileSync(dest, "garbage-without-tabs\n");
  else fs.appendFileSync(dest, "1\tPASS\tforged-pass\t" + process.argv[1] + "\n");
  if (process.env.FORGE_MODE === "hide-fail") throw new Error("real failure");
});
EOF
case_begin "forged-or-malformed-reporter-record" "bin/lib/test-wrappers/node.js"
export FORGE_MODE
for FORGE_MODE in malformed hide-fail; do
  run_node "$T/r-forge-$FORGE_MODE" "$T/fx/forge.js" 20.0
  assert_eq "forge $FORGE_MODE: rc=$PRC" "forge $FORGE_MODE: rc=1"
  if [ "$FORGE_MODE" = hide-fail ]; then
    if tsv_has "$T/r-forge-$FORGE_MODE" FAIL forge; then pass "forge hide-fail: real FAIL record kept"; else fail "forge hide-fail: real FAIL record missing" "$(head -c 300 "$T/r-forge-$FORGE_MODE.out" 2>/dev/null)"; fi
  fi
  if [ -f "$T/r-forge-$FORGE_MODE/cases.tsv" ] && grep -q 'garbage-without-tabs' "$T/r-forge-$FORGE_MODE/cases.tsv"; then fail "forge $FORGE_MODE: malformed line copied to result dir"; else pass "forge $FORGE_MODE: malformed line not copied"; fi
done
unset FORGE_MODE
case_end

echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
