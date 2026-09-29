#!/usr/bin/env bash
# tests/hooks/feature-2431-run-tests-failing-list.sh
# Tests: hooks/workflow-run-tests/failing-list.js, hooks/workflow-run-tests.js
# Tags: TL1, TL2, scope:issue-specific
# TDD stage-5: failing-list.js absent until impl; hook annotations absent until
# workflow-run-tests.js is extended.  Two source paths → case markers required.
# TL3 gap: no real claude -p; hook driven as subprocess with hand-built JSON.
# Mitigation: hook-registration in bin/check-verification-gate.sh.

set -uo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

TMPD="$(make_tmp)"
trap 'rm -rf "$TMPD"' EXIT
harness_isolate "$TMPD"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE 2>/dev/null || true

AGENTS_WIN="$(np "$AGENTS_DIR")"
RUN_TESTS_HOOK="$AGENTS_DIR/hooks/workflow-run-tests.js"
FAILING_LIST_JS="$AGENTS_WIN/hooks/workflow-run-tests/failing-list.js"
RUN_ALL_LAUNCH="$AGENTS_DIR/bin/lib/run-all-launch.sh"

# Fixture repo for run-all.sh provenance checks (TL2 cases).
FIXTURE_REPO="$TMPD/repo"
harness_git_init "$FIXTURE_REPO"
git -C "$FIXTURE_REPO" config user.email test@example.com
git -C "$FIXTURE_REPO" config user.name "Test"
mkdir -p "$FIXTURE_REPO/tests"
cp "$AGENTS_DIR/tests/run-all.sh" "$FIXTURE_REPO/tests/run-all.sh"
FIXTURE_WIN="$(np "$FIXTURE_REPO")"

step_field() {
    run_with_timeout 30 node -e '
try {
  var s=require(process.argv[1]+"/hooks/workflow-state").readState(process.argv[2]);
  var e=s&&s.steps&&s.steps[process.argv[3]];
  var v=e?e[process.argv[4]]:undefined;
  process.stdout.write(v===undefined||v===null?"(absent)":JSON.stringify(v));
} catch(er){process.stdout.write("(absent)");}
' "$AGENTS_WIN" "$1" "$2" "$3" 2>/dev/null || echo "(absent)"
}

seed_step() {
    run_with_timeout 30 node -e '
var x={};
if(process.argv[5])x[process.argv[5]]=process.argv[6]||null;
require(process.argv[1]+"/hooks/workflow-state")
  .markStep(process.argv[2],process.argv[3],process.argv[4],x);
' "$AGENTS_WIN" "$1" "$2" "$3" "${4:-}" "${5:-}" >/dev/null 2>&1 || true
}

drive_hook() {
    local _cwd="${5:-$AGENTS_WIN}"
    run_with_timeout 30 node -e '
var p={tool_name:"Bash",tool_input:{command:process.argv[1],cwd:process.argv[5]},
  tool_response:{exit_code:parseInt(process.argv[2],10),stdout:process.argv[3]},
  session_id:process.argv[4]};
process.stdout.write(JSON.stringify(p));
' "$1" "$2" "$4" "$3" "$_cwd" 2>/dev/null \
        | run_with_timeout 30 node "$RUN_TESTS_HOOK" >/dev/null 2>&1 || true
}

# Write the JS unit-test runner once; reused across case groups.
cat > "$TMPD/fl-runner.js" << 'JSEOF'
"use strict";
var m;
try { m = require(process.argv[2]); }
catch (e) {
  process.stdout.write("MODULE_MISSING:" + e.message.split("\n")[0] + "\n");
  process.exit(0);
}
function ok(name, cond, detail) {
  process.stdout.write((cond?"PASS:":"FAIL:") + name
    + ((!cond&&detail)?" -- "+detail:"") + "\n");
}
var EFT = m.extractFailingTests;
var CTK = m.classifyTestKind;
var NTP = m.normalizeTestPath;
ok("exports-extractFailingTests", typeof EFT==="function");
ok("exports-classifyTestKind",    typeof CTK==="function");
ok("exports-normalizeTestPath",   typeof NTP==="function");
if (typeof EFT!=="function"||typeof CTK!=="function") process.exit(0);

var root = process.argv[3];
var R = root + "/";
function fl(p, rc) { return "FAIL: " + p + " (exit " + (rc === undefined ? 1 : rc) + ")"; }
function wk(items, tail) {
  return ["RUN_CONTRACT: PASS=0 FAIL=" + items.length + " SKIP=0 EXECUTED=" + items.length,
    "status: fail", "exit_code: 1", "summary: 'x failed'", "failing_tests:"]
    .concat(items.map(function (p) { return "  - '" + p.replace(/'/g, "''") + "'"; }))
    .concat(["log_tail: |"], tail || ["  suite done"]).join("\n");
}

// extractFailingTests matrix: [name, isWorker, stdout, contract.fail, want (array | null)].
var EFT_CASES = [
  ["run-all/three-kinds-abs",        false, [fl(R+"tests/a.sh"), fl(R+"tests/b.Tests.ps1"), fl(R+"tests/test_c.py", 2), "Results: PASS=0 FAIL=3 SKIP=0"].join("\n"), 3, ["tests/a.sh","tests/b.Tests.ps1","tests/test_c.py"]],
  ["run-all/relative-path",          false, fl("tests/r.sh"), 1, ["tests/r.sh"]],
  ["run-all/dot-slash-stripped",     false, fl("./tests/r.sh"), 1, ["tests/r.sh"]],
  ["run-all/backslash-normalized",   false, fl("tests\\sub\\w.sh"), 1, ["tests/sub/w.sh"]],
  ["run-all/negative-exit-code",     false, fl("tests/n.sh", -1), 1, ["tests/n.sh"]],
  ["run-all/crlf-lines",             false, fl("tests/c1.sh") + "\r\n" + fl("tests/c2.sh") + "\r\n", 2, ["tests/c1.sh","tests/c2.sh"]],
  ["run-all/non-contract-fail-noise",false, "FAIL: tests/noise.sh\n  FAIL: tests/indent.sh (exit 1)\n" + fl("tests/v.sh"), 1, ["tests/v.sh"]],
  ["run-all/zero-failures",          false, "Results: PASS=3 FAIL=0 SKIP=0", 0, []],
  ["run-all/count-over",             false, fl("tests/a.sh"), 99, null],
  ["run-all/count-under",            false, fl("tests/a.sh") + "\n" + fl("tests/b.sh"), 1, null],
  ["run-all/traversal-abs",          false, fl(R+"../x/tests/e.sh"), 1, null],
  ["run-all/traversal-rel",          false, fl("tests/../bin/e.sh"), 1, null],
  ["run-all/traversal-backslash",    false, fl("tests\\..\\bin\\e.sh"), 1, null],
  ["run-all/outside-tests-dir",      false, fl(R+"bin/foo.sh"), 1, null],
  ["run-all/outside-root-sibling",   false, fl(root+"-other/tests/x.sh"), 1, null],
  ["run-all/outside-root-foreign",   false, fl("/elsewhere/repo/tests/x.sh"), 1, null],
  ["run-all/unsupported-kind-txt",   false, fl("tests/x.txt"), 1, null],
  ["run-all/py-without-test-prefix", false, fl("tests/tc.py"), 1, null],
  ["run-all/one-bad-withholds-all",  false, fl("tests/ok.sh") + "\n" + fl("bin/bad.sh"), 2, null],
  ["run-all/ignores-worker-yaml",    false, wk([R+"tests/d.sh"]), 1, null],
  ["worker/two-kinds-abs",           true,  wk([R+"tests/d.sh", R+"tests/e.Tests.ps1"]), 2, ["tests/d.sh","tests/e.Tests.ps1"]],
  ["worker/pytest-kind",             true,  wk(["tests/test_p.py"]), 1, ["tests/test_p.py"]],
  ["worker/quoted-apostrophe",       true,  wk([R+"tests/it's.sh"]), 1, ["tests/it's.sh"]],
  ["worker/quoted-space",            true,  wk(["tests/a b.sh"]), 1, ["tests/a b.sh"]],
  ["worker/log-tail-items-ignored",  true,  wk(["tests/real.sh"], ["  - 'tests/in-log.sh'"]), 1, ["tests/real.sh"]],
  ["worker/unquoted-item-ends-list", true,  "failing_tests:\n  - tests/u.sh\nlog_tail: |", 1, null],
  ["worker/count-mismatch",          true,  wk([R+"tests/d.sh", R+"tests/e.sh"]), 99, null],
  ["worker/traversal",               true,  wk([R+"../x/tests/e.sh"]), 1, null],
  ["worker/outside-root",            true,  wk([root+"-other/tests/x.sh"]), 1, null],
  ["worker/outside-tests-dir",       true,  wk([R+"hooks/x.sh"]), 1, null],
  ["worker/unsupported-kind",        true,  wk(["tests/x.js"]), 1, null],
  ["worker/ignores-run-all-lines",   true,  fl("tests/a.sh"), 1, null],
];
for (var i = 0; i < EFT_CASES.length; i++) {
  var c = EFT_CASES[i];
  var got = EFT({stdout: c[2], isWorker: c[1], worktreeRoot: root,
    contract: {pass: 0, fail: c[3], skip: 0, executed: c[3]}});
  ok("eft/" + c[0], JSON.stringify(got) === JSON.stringify(c[4]),
    "want=" + JSON.stringify(c[4]) + " got=" + JSON.stringify(got));
}

// Guard inputs: [name, args, want].
var GUARD_CASES = [
  ["eft/no-contract",        {stdout: fl("tests/a.sh"), isWorker: false, worktreeRoot: root}, null],
  ["eft/contract-fail-nan",  {stdout: fl("tests/a.sh"), isWorker: false, worktreeRoot: root, contract: {fail: "1"}}, null],
  ["eft/stdout-not-string",  {stdout: null, isWorker: false, worktreeRoot: root, contract: {fail: 0}}, null],
  ["eft/abs-without-root",   {stdout: fl(R+"tests/a.sh"), isWorker: false, worktreeRoot: "", contract: {fail: 1}}, null],
];
GUARD_CASES.forEach(function (g) {
  var got = EFT(g[1]);
  ok(g[0], JSON.stringify(got) === JSON.stringify(g[2]), "got=" + JSON.stringify(got));
});

// classifyTestKind matrix mirrors run-all-launch.sh's three dispatch branches.
[["classify/sh", "tests/a.sh", "bash"], ["classify/ps1", "tests/b.Tests.ps1", "pester"],
 ["classify/py", "tests/test_c.py", "pytest"], ["classify/backslash-dir", "tests\\d\\e.sh", "bash"],
 ["classify/plain-ps1", "tests/x.ps1", null], ["classify/py-no-prefix", "tests/tc.py", null],
 ["classify/txt", "tests/x.txt", null], ["classify/bare-ext-sh", "tests/.sh", null],
 ["classify/non-string", 42, null]].forEach(function (k) {
  var got = CTK(k[1]);
  ok(k[0], got === k[2], "want=" + k[2] + " got=" + got);
});

// normalizeTestPath: [name, input, root, want].
[["ntp/strips-root", R+"tests/x.sh", root, "tests/x.sh"],
 ["ntp/trims-whitespace", "  tests/x.sh  ", root, "tests/x.sh"],
 ["ntp/empty", "   ", root, null],
 ["ntp/abs-no-root", R+"tests/x.sh", undefined, null],
 ["ntp/root-trailing-slash", R+"tests/x.sh", R, "tests/x.sh"]].forEach(function (n) {
  var got = NTP(n[1], n[2]);
  ok(n[0], got === n[3], "want=" + n[3] + " got=" + got);
});
JSEOF

# ============================================================================
case_begin "failing-list-functions" "hooks/workflow-run-tests/failing-list.js"
# ============================================================================

echo ""
echo "=== failing-list-functions ==="

_fl_out=$(run_with_timeout 60 node "$TMPD/fl-runner.js" "$FAILING_LIST_JS" "$FIXTURE_WIN" 2>/dev/null || echo "ERR:crashed")

while IFS= read -r _ln; do
    case "$_ln" in
        MODULE_MISSING:*) fail "failing-list-module-exists" "${_ln#MODULE_MISSING:}" ;;
        PASS:*)           pass "${_ln#PASS:}" ;;
        FAIL:*)           fail "${_ln#FAIL:}" ;;
        ERR:*)            fail "fl-runner-crashed" "$_ln" ;;
    esac
done <<< "$_fl_out"

# Static cross-check: classifyTestKind must correspond to run-all-launch.sh's
# 3 case branches.  A mismatch would silently mis-classify baseline runs.
if [ -f "$RUN_ALL_LAUNCH" ]; then
    if grep -q '\.Tests\.ps1' "$RUN_ALL_LAUNCH" 2>/dev/null; then
        pass "static/run-all-launch-Tests-ps1-branch"
    else
        fail "static/run-all-launch-Tests-ps1-branch" "branch not found in $RUN_ALL_LAUNCH"
    fi
    if grep -q 'test_\*\.py' "$RUN_ALL_LAUNCH" 2>/dev/null; then
        pass "static/run-all-launch-test-py-branch"
    else
        fail "static/run-all-launch-test-py-branch"
    fi
else
    fail "static/run-all-launch-exists" "not found: $RUN_ALL_LAUNCH"
fi

case_end

# ============================================================================
case_begin "hook-annotation-integration" "hooks/workflow-run-tests.js"
# ============================================================================

echo ""
echo "=== hook-annotation-integration ==="

# A0: new keys must be registered in STEP_ANNOTATION_KEYS; without this,
# markStep() silently ignores them and later value checks are false-greens.
_keys=$(run_with_timeout 30 node -e '
try {
  var k=require(process.argv[1]+"/hooks/workflow-state/state-io/events").STEP_ANNOTATION_KEYS;
  process.stdout.write(Array.isArray(k)?k.join(","):"(absent)");
} catch(e){process.stdout.write("(absent)");}
' "$AGENTS_WIN" 2>/dev/null || echo "(absent)")

case "$_keys" in *failing_tests*)         pass "A0/failing_tests-registered" ;;
    *) fail "A0/failing_tests-registered" "keys=$_keys" ;; esac
case "$_keys" in *baseline_classification*) pass "A0/baseline_classification-registered" ;;
    *) fail "A0/baseline_classification-registered" "keys=$_keys" ;; esac
case "$_keys" in *completion_basis*)        pass "A0/completion_basis-registered" ;;
    *) fail "A0/completion_basis-registered" "keys=$_keys" ;; esac

# Trusted provenance (NEW-M1): the emitter must be THIS checkout's tests/run-all.sh
# (a standalone fixture repo has a foreign git common dir, so its RUN_CONTRACT is
# not adopted). State writes stay isolated by harness_isolate.
TRUSTED_WIN="$AGENTS_WIN"

# A1: failing run with trusted provenance records failing_tests (non-absent).
_sid_a1="f2431-fl-a1-$$"
seed_step "$_sid_a1" write_tests complete
_so_a1=$(printf '%s\n' \
    "FAIL: $TRUSTED_WIN/tests/failing-test.sh (exit 1)" \
    "Results: PASS=0 FAIL=1 SKIP=0" \
    "RUN_CONTRACT: PASS=0 FAIL=1 SKIP=0 EXECUTED=1")
drive_hook "bash $TRUSTED_WIN/tests/run-all.sh" 1 "$_sid_a1" "$_so_a1" "$TRUSTED_WIN"
_ft_a1=$(step_field "$_sid_a1" run_tests failing_tests)
if [ "$_ft_a1" = "(absent)" ]; then
    fail "A1/failing-run-records-failing-tests" "got (absent); hook not yet extended"
else
    pass "A1/failing-run-records-failing-tests"
fi

# A5: 11 failures (> old 10-cap) end-to-end → every path recorded, none truncated.
_sid_a5="f2431-fl-a5-$$"
seed_step "$_sid_a5" write_tests complete
_a5_paths=()
for _i in 01 02 03 04 05 06 07 08 09; do _a5_paths+=("tests/ft-$_i.sh"); done
_a5_paths+=("tests/ft-10.Tests.ps1" "tests/test_ft_11.py")
_so_a5=""
for _p in "${_a5_paths[@]}"; do _so_a5+="FAIL: $TRUSTED_WIN/$_p (exit 1)"$'\n'; done
_so_a5+="Results: PASS=0 FAIL=11 SKIP=0"$'\n'"RUN_CONTRACT: PASS=0 FAIL=11 SKIP=0 EXECUTED=11"
drive_hook "bash $TRUSTED_WIN/tests/run-all.sh" 1 "$_sid_a5" "$_so_a5" "$TRUSTED_WIN"
_ft_a5=$(step_field "$_sid_a5" run_tests failing_tests)
_n_a5=$(run_with_timeout 10 node -e 'try{var v=JSON.parse(process.argv[1]);process.stdout.write(Array.isArray(v)?String(v.length):"not-array");}catch(e){process.stdout.write("unparsable");}' "$_ft_a5" 2>/dev/null || echo "err")
if [ "$_n_a5" = "11" ]; then pass "A5/eleven-failures-count"
else fail "A5/eleven-failures-count" "len=$_n_a5 failing_tests=$_ft_a5"; fi
_a5_missing=""
for _p in "${_a5_paths[@]}"; do
    case "$_ft_a5" in *"\"$_p\""*) ;; *) _a5_missing+=" $_p" ;; esac
done
if [ -z "$_a5_missing" ]; then
    pass "A5/eleven-failures-all-paths-recorded"
else
    fail "A5/eleven-failures-all-paths-recorded" "missing:$_a5_missing; got=$_ft_a5"
fi

# A2: untrusted provenance → failing_tests null (absent after tombstone).
_sid_a2="f2431-fl-a2-$$"
seed_step "$_sid_a2" write_tests complete
_so_a2=$(printf '%s\n' \
    "FAIL: /tmp/nowhere-$$/tests/x.sh (exit 1)" \
    "Results: PASS=0 FAIL=1 SKIP=0" \
    "RUN_CONTRACT: PASS=0 FAIL=1 SKIP=0 EXECUTED=1")
drive_hook "bash /tmp/nowhere-$$/tests/run-all.sh" 1 "$_sid_a2" "$_so_a2" "/tmp"
_ft_a2=$(step_field "$_sid_a2" run_tests failing_tests)
assert_eq "$_ft_a2" "(absent)" "A2/untrusted-provenance-failing-tests-null"

# A3: complete branch tombstones failing_tests (and baseline evidence).
# Seed non-null failing_tests, then drive a valid PASS.
_sid_a3="f2431-fl-a3-$$"
seed_step "$_sid_a3" write_tests complete
seed_step "$_sid_a3" run_tests pending failing_tests '["tests/old.sh"]'
_prev=$(step_field "$_sid_a3" run_tests failing_tests)
if [ "$_prev" = "(absent)" ]; then
    fail "A3/precondition-seed-failing-tests" "key not registered; A0 should have caught this"
else
    _so_a3=$(printf '%s\n' \
        "Results: PASS=1 FAIL=0 SKIP=0" \
        "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1")
    drive_hook "bash $TRUSTED_WIN/tests/run-all.sh" 0 "$_sid_a3" "$_so_a3" "$TRUSTED_WIN"
    assert_eq "$(step_field "$_sid_a3" run_tests failing_tests)"          "(absent)" "A3/complete-tombstones-failing-tests"
    assert_eq "$(step_field "$_sid_a3" run_tests baseline_classification)" "(absent)" "A3/complete-tombstones-baseline-classification"
    assert_eq "$(step_field "$_sid_a3" run_tests completion_basis)"        "(absent)" "A3/complete-tombstones-completion-basis"
fi

# A4: demotion branch tombstones baseline evidence.
_sid_a4="f2431-fl-a4-$$"
seed_step "$_sid_a4" write_tests complete
seed_step "$_sid_a4" run_tests complete baseline_classification preexisting
drive_hook "bash $TRUSTED_WIN/tests/run-all.sh" 1 "$_sid_a4" "no contract" "$TRUSTED_WIN"
assert_eq "$(step_field "$_sid_a4" run_tests baseline_classification)" "(absent)" "A4/demotion-tombstones-baseline-classification"
assert_eq "$(step_field "$_sid_a4" run_tests completion_basis)"        "(absent)" "A4/demotion-tombstones-completion-basis"

case_end

# ============================================================================
case_begin "worker-yaml-fifteen-failures-e2e" "hooks/workflow-run-tests.js"
# ============================================================================

echo ""
echo "=== worker-yaml-fifteen-failures-e2e ==="

# W1: worker route end to end. The YAML is produced by the REAL renderer
# (bin/worker-dispatch/emit.js renderTestRunnerYaml) from a 15-entry
# failingTests list, then fed to the hook under the canonical worker-dispatch
# command. Any surviving 10-cap (renderer MAX_FAILING_TESTS or the hook's
# header parse) drops entries 11..15 and fails here.
_sid_w1="f2431-fl-w1-$$"
seed_step "$_sid_w1" write_tests complete
_w1_rel=()
for _i in 01 02 03 04 05 06 07 08 09 10 11 12 13; do _w1_rel+=("tests/wk-$_i.sh"); done
_w1_rel+=("tests/wk-14.Tests.ps1" "tests/test_wk_15.py")
_w1_yaml=$(run_with_timeout 30 node -e '
try {
  var r=require(process.argv[1]+"/bin/worker-dispatch/emit.js").renderTestRunnerYaml;
  var root=process.argv[2], rel=process.argv.slice(3);
  process.stdout.write(r({status:"fail",exitCode:1,durationSeconds:3,
    summary:"PASS=0 FAIL=15 SKIP=0",runContract:{pass:0,fail:15,skip:0,executed:15},
    failingTests:rel.map(function(p){return root+"/"+p}),logTail:["suite done"]}));
}
catch(e){process.stdout.write("RENDER_ERROR:"+e.message)}
' "$AGENTS_WIN" "$AGENTS_WIN" "${_w1_rel[@]}" 2>/dev/null || echo "RENDER_ERROR:crashed")
case "$_w1_yaml" in
    RENDER_ERROR:*) fail "W1/renderer-available" "$_w1_yaml" ;;
    *) pass "W1/renderer-available" ;;
esac
_w1_listed=0
for _p in "${_w1_rel[@]}"; do
    case "$_w1_yaml" in *"$_p'"*) _w1_listed=$((_w1_listed + 1)) ;; esac
done
assert_eq "$_w1_listed" "15" "W1/renderer-emits-all-15-failing-tests"
_w1_cmd="node \"$AGENTS_WIN/bin/worker-dispatch.js\" test-runner \"$AGENTS_WIN\" \"$TMPD/sid-w1.json\""
drive_hook "$_w1_cmd" 0 "$_sid_w1" "$_w1_yaml" "$AGENTS_WIN"
_ft_w1=$(step_field "$_sid_w1" run_tests failing_tests)
_w1_missing=""
for _p in "${_w1_rel[@]}"; do
    case "$_ft_w1" in *"\"$_p\""*) ;; *) _w1_missing+=" $_p" ;; esac
done
if [ -z "$_w1_missing" ]; then
    pass "W1/worker-route-all-15-paths-persisted"
else
    fail "W1/worker-route-all-15-paths-persisted" "missing:$_w1_missing; got=$_ft_w1"
fi

case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
