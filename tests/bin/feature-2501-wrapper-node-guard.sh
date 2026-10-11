#!/usr/bin/env bash
# tests/bin/feature-2501-wrapper-node-guard.sh
# Tests: bin/lib/test-wrappers/node-guard.cjs, bin/lib/test-wrappers/node.js
# Tags: scope:issue-specific, test-language-wrapper, node, node-test, run-all, security, tl2
# Node guard (#2501 D4-3): the --require guard leaves the marker named by RUN_ALL_NODE_GUARD_MARKER
# only when the run actually loaded node:test, keeps the script's own exit code and output, and
# hides that env var from the script. The wrapper runs each file once and picks the node:test or
# plain-script exit table from that marker and the reporter's records, never from the source text.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 77; }

GUARD="$SCRIPT_CHECKOUT_ROOT/bin/lib/test-wrappers/node-guard.cjs"
WRAPPER="$SCRIPT_CHECKOUT_ROOT/bin/lib/test-wrappers/node.js"
T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/det" "$T/cwd"
unset RUN_ALL_NODE_GUARD_MARKER RUN_ALL_TIMEOUT_SECONDS

# guarded <name> — runs $T/<name>.js under the guard with the marker at $T/<name>.marker;
# rc in GRC, output in $T/<name>.out.
guarded() {
  GRC=0
  RUN_ALL_NODE_GUARD_MARKER="$(np "$T/$1.marker")" run_with_timeout 60 node --require "$(np "$GUARD")" "$(np "$T/$1.js")" >"$T/$1.out" 2>&1 </dev/null || GRC=$?
}

# marker <name> — "marker" when that run left its marker file, else "none".
marker() { if [ -f "$T/$1.marker" ]; then echo marker; else echo none; fi; }

# out_bytes <name> — size of that run's combined output.
out_bytes() { wc -c <"$T/$1.out" | tr -d ' \r\n'; }

# run_node <resdir> <fixture> — direct wrapper launch (minVersion 20.0); rc in PRC.
run_node() {
  local res="$1" fx="$2"
  mkdir -p "$res"
  PRC=0
  (
    cd "$T/cwd" || exit 2
    export RUN_ALL_RESULT_DIR RUN_ALL_RESULT_OWNER
    RUN_ALL_RESULT_DIR="$(np "$res")"
    RUN_ALL_RESULT_OWNER="$fx"
    run_with_timeout 120 node "$(np "$WRAPPER")" "$(np "$fx")" 20.0 >"$res.out" 2>&1 </dev/null
  ) || PRC=$?
}

# tsv_total <resdir> / tsv_has <resdir> <STATE> <case> — cases.tsv record count / exact record.
tsv_total() { if [ -f "$1/cases.tsv" ]; then awk 'NF{n++} END{print n+0}' "$1/cases.tsv"; else echo 0; fi; }
tsv_has() { [ -f "$1/cases.tsv" ] && awk -F'\t' -v s="$2" -v c="$3" '$2==s && $3==c{f=1} END{exit !f}' "$1/cases.tsv"; }

printf '%s\n' 'module.exports = require("node:test");' >"$T/helper.js"
printf '%s\n' 'require("./helper.js");' >"$T/via-helper.js"
printf '%s\n' 'const m = "node:" + "test";' 'require(m);' 'process.exit(0);' >"$T/explicit-exit0.js"
printf '%s\n' 'const m = "node:" + "test";' 'require(m);' 'process.exit(77);' >"$T/explicit-exit77.js"
printf '%s\n' 'const m = "node:" + "test";' 'require(m);' 'process.exit(3);' >"$T/explicit-exit3.js"
printf '%s\n' 'import("node:" + "test").then(() => {});' >"$T/dynamic.js"
printf '%s\n' 'require("assert").ok(true);' >"$T/plain-ok.js"
printf '%s\n' 'process.exit(77);' >"$T/plain-77.js"
printf '%s\n' 'process.exit(3);' >"$T/plain-3.js"
printf '%s\n' 'if (false) require("node:test");' 'process.exit(0);' >"$T/dead-code.js"
printf '%s\n' 'require("./helper.js");' 'process.stdout.write("[" + (process.env.RUN_ALL_NODE_GUARD_MARKER || "") + "]");' >"$T/env-probe.js"

case_begin "guard-file-present" "bin/lib/test-wrappers/node-guard.cjs"
if [ -f "$GUARD" ]; then pass "node-guard.cjs present"; else fail "node-guard.cjs missing" "$GUARD"; fi
case_end

case_begin "node-test-loaded-at-run-time-leaves-marker" "bin/lib/test-wrappers/node-guard.cjs"
while read -r name rc; do
  guarded "$name"
  assert_eq "$name: rc=$GRC $(marker "$name") out-bytes=$(out_bytes "$name")" "$name: rc=$rc marker out-bytes=0"
done <<'TABLE'
via-helper 0
explicit-exit0 0
explicit-exit77 77
explicit-exit3 3
dynamic 0
TABLE
case_end

case_begin "script-without-node-test-leaves-no-marker" "bin/lib/test-wrappers/node-guard.cjs"
# dead-code: the import is in the text but never runs, so node:test is never loaded.
while read -r name rc; do
  guarded "$name"
  assert_eq "$name: rc=$GRC $(marker "$name") out-bytes=$(out_bytes "$name")" "$name: rc=$rc none out-bytes=0"
done <<'TABLE'
plain-ok 0
plain-77 77
plain-3 3
dead-code 0
TABLE
case_end

case_begin "marker-env-is-hidden-from-the-script" "bin/lib/test-wrappers/node-guard.cjs"
guarded env-probe
assert_eq "env-probe: rc=$GRC $(marker env-probe) out=$(cat "$T/env-probe.out")" "env-probe: rc=0 marker out=[]"
case_end

case_begin "no-marker-env-is-a-no-op" "bin/lib/test-wrappers/node-guard.cjs"
nrc=0
run_with_timeout 60 node --require "$(np "$GUARD")" "$(np "$T/via-helper.js")" >"$T/noenv.out" 2>&1 </dev/null || nrc=$?
assert_eq "no-env: rc=$nrc out-bytes=$(wc -c <"$T/noenv.out" | tr -d ' \r\n')" "no-env: rc=0 out-bytes=0"
case_end

# The wrapper's path is read back from the outcome: a node:test run leaves records (or 77 with no
# test); a plain script leaves none and keeps 0 / 1. Test cases in node-test rows are all named "t".
# Table: <case-id>|<ext>|<source, lines joined by \n>|<expected path: plain|node-test>|<expected exit>.
case_begin "node-test-decided-by-what-the-run-loads" "bin/lib/test-wrappers/node.js"
while IFS='|' read -r dn dext dsrc dpath drc; do
  [[ -z "$dn" || "$dn" =~ ^[[:space:]]*# ]] && continue
  printf '%b\n' "$dsrc" >"$T/det/$dn.$dext"
  run_node "$T/r-det-$dn" "$T/det/$dn.$dext"
  drec="$(tsv_total "$T/r-det-$dn")"
  if [ "$drec" -gt 0 ] || [ "$PRC" = 77 ]; then dgot=node-test; else dgot=plain; fi
  assert_eq "$dn: path=$dgot rc=$PRC" "$dn: path=$dpath rc=$drc"
  if [ "$dpath" = node-test ] && [ "$drc" = 0 ]; then
    if tsv_has "$T/r-det-$dn" PASS t; then pass "$dn: PASS record for t"; else fail "$dn: PASS record for t missing" "$(head -c 300 "$T/r-det-$dn.out" 2>/dev/null)"; fi
  fi
done <<'TABLE'
# mentions only (comment / string / template / regex literal): never loaded, a plain script
line-comment|js|// uses "node:test" style\nconst assert = require("assert");\nassert.strictEqual(1, 1);|plain|0
block-multiline|js|/*\n * import test from "node:test";\n */\nrequire("assert").ok(true);|plain|0
string-literal-dq|js|const s = "node:test";\nconsole.log(s);|plain|0
commented-import|mjs|// import test from "node:test";\nconsole.log("x");|plain|0
comment-fail|js|// "node:test"\nrequire("assert").strictEqual(1, 2);|plain|1
string-holds-require-sq|js|const s = 'require("node:test")';\nrequire("assert").ok(s.length > 0);|plain|0
template-holds-import|js|const s = `import test from "node:test";`;\nrequire("assert").ok(s.length > 0);|plain|0
regex-holds-require|js|const re = /require("node:test")/;\nrequire("assert").ok(re.source.length > 0);|plain|0
# a literal import in code that never runs: no marker, no record, the file's own exit code stands
require-in-dead-code|js|if (false) require("node:test");\nrequire("assert").ok(true);|plain|0
require-in-dead-code-fail|js|if (false) require("node:test");\nrequire("assert").ok(false);|plain|1
# node:test reached by any route the text does not show: the node:test exit table
require-via-variable-all-skipped|js|const m = "node:" + "test";\nconst test = require(m);\ntest("t", { skip: true }, () => {});|node-test|77
require-via-template-substitution|js|const n = "test";\nconst test = require(`node:${n}`);\ntest("t", () => {});|node-test|0
import-dynamic-via-variable|js|const m = ["node", "test"].join(":");\nimport(m).then(({ test }) => { test("t", { skip: true }, () => {}); });|node-test|77
require-via-variable-no-test|js|const m = "node:" + "test";\nrequire(m);|node-test|77
# real imports
require-dq|js|const test = require("node:test");\ntest("t", () => {});|node-test|0
require-sq-destructure|js|const { test } = require('node:test');\ntest("t", () => {});|node-test|0
import-default-dq|mjs|import test from "node:test";\ntest("t", () => {});|node-test|0
import-named-multiline|mjs|import {\n  test,\n} from "node:test";\ntest("t", () => {});|node-test|0
import-dynamic|js|import("node:test").then(({ test }) => { test("t", () => {}); });|node-test|0
import-side-effect|mjs|import "node:test";|node-test|77
# a failing todo test is an expected result, as node itself counts it
todo-fail-is-expected|js|const test = require("node:test");\ntest("t", () => {});\ntest("later", { todo: true }, () => { throw new Error("x"); });|node-test|0
TABLE
case_end

# Single run (D4-3): the wrapper launches the file exactly once on every path, so a plain script's
# side effect happens once and a node:test file's tests run once.
printf '%s\n' 'require("fs").appendFileSync(process.env.PROBE_OUT, "x");' >"$T/det/once-plain.js"
printf '%s\n' 'const test = require("node:test");' 'require("fs").appendFileSync(process.env.PROBE_OUT, "x");' 'test("t", () => {});' >"$T/det/once-nt.js"
printf '%s\n' 'const test = require("node:test");' 'require("fs").appendFileSync(process.env.PROBE_OUT, "x");' >"$T/det/once-zero.js"
case_begin "each-file-runs-once" "bin/lib/test-wrappers/node.js"
for once in once-plain once-nt once-zero; do
  export PROBE_OUT
  PROBE_OUT="$(np "$T/$once.count")"
  run_node "$T/r-$once" "$T/det/$once.js"
  unset PROBE_OUT
  assert_eq "$once: runs=$(cat "$T/$once.count" 2>/dev/null)" "$once: runs=x"
done
case_end

echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
