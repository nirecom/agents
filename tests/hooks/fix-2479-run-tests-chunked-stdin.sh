#!/usr/bin/env bash
# tests/hooks/fix-2479-run-tests-chunked-stdin.sh
# Tests: hooks/workflow-run-tests.js, hooks/lib/read-stdin.js
# Tags: TL2, hook, stdin, run-tests, scope:common
# TL3 gap (what this test does NOT catch):
# - Real Claude Code PostToolUse delivery of a large Bash tool_response (no claude -p;
#   the hook is driven as a subprocess with a replayed envelope and a chunked writer).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -uo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

TMPD="$(make_tmp)"
trap 'rm -rf "$TMPD"' EXIT
harness_isolate "$TMPD"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE 2>/dev/null || true
mkdir -p "$TMPD/transcripts"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPD/transcripts"

AGENTS_WIN="$(np "$AGENTS_DIR")"
TMPW="$(np "$TMPD")"
RUN_TESTS_HOOK="$AGENTS_DIR/hooks/workflow-run-tests.js"

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
require(process.argv[1]+"/hooks/workflow-state").markStep(process.argv[2],process.argv[3],process.argv[4],{});
' "$AGENTS_WIN" "$1" "$2" "$3" >/dev/null 2>&1 || true
}

check() { # check <name> <want> <got>
    if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "want=$2 got=$3"; fi
}

# chunked-writer.js <payload> <delayMs|single>: two writes split inside a
# multibyte char near the middle, <delayMs> apart; "single" = one write.
cat > "$TMPD/chunked-writer.js" << 'JSEOF'
"use strict";
const data = require("fs").readFileSync(process.argv[2]);
if (process.argv[3] === "single") {
  process.stdout.write(data);
} else {
  let mid = Math.floor(data.length / 2);
  for (let i = mid; i < data.length && i < mid + 8192; i++) {
    if ((data[i] & 0xc0) === 0x80) { mid = i; break; }
  }
  process.stdout.write(data.subarray(0, mid), () => {
    setTimeout(() => process.stdout.write(data.subarray(mid)), Number(process.argv[3]));
  });
}
JSEOF

# build-payload.js <ch1|ch2> <agentsWin> <sid> <out> <tmpWin>: replayed
# PostToolUse envelope for a Bash tool call; prints the payload byte length.
cat > "$TMPD/build-payload.js" << 'JSEOF'
"use strict";
const fs = require("fs");
const [kind, root, sid, out, tmp] = process.argv.slice(2);
let command, description, stdout, extra = {}, toolCwd = {};
if (kind === "ch1") {
  const render = require(root + "/bin/worker-dispatch/emit.js").renderTestRunnerYaml;
  const rel = [];
  for (let i = 1; i <= 15; i++) rel.push("tests/ch-" + String(i).padStart(2, "0") + ".sh");
  const logTail = [];
  for (let i = 1; i <= 40; i++) {
    logTail.push("ログ行 " + i + ": テスト実行の出力（マルチバイト）— 失敗の詳細をここに記録する ".repeat(2) + "end");
  }
  stdout = render({ status: "fail", exitCode: 1, durationSeconds: 12, summary: "PASS=0 FAIL=15 SKIP=0",
    runContract: { pass: 0, fail: 15, skip: 0, executed: 15 },
    failingTests: rel.map((p) => root + "/" + p), logTail });
  command = 'node "' + root + '/bin/worker-dispatch.js" test-runner "' + root + '" "' + tmp + '/sid-ch1.json"';
  description = "Run tests via worker-dispatch";
} else {
  const lines = [];
  let n = 0, bytes = 0;
  while (bytes <= 66000) {
    const l = "ノイズ " + String(++n).padStart(5, "0") + ": テスト出力の水増し行 — ok";
    lines.push(l); bytes += Buffer.byteLength(l, "utf8") + 1;
  }
  lines.push("FAIL: " + root + "/tests/a.sh (exit 1)", "FAIL: " + root + "/tests/b.sh (exit 1)",
    "Results: PASS=0 FAIL=2 SKIP=0", "RUN_CONTRACT: PASS=0 FAIL=2 SKIP=0 EXECUTED=2");
  stdout = lines.join("\n") + "\n";
  command = "bash " + root + "/tests/run-all.sh";
  description = "Run all tests";
  extra = { exit_code: 1 };
  toolCwd = { cwd: root };
}
const payload = {
  session_id: sid, transcript_path: tmp + "/transcripts/" + sid + ".jsonl", cwd: root,
  hook_event_name: "PostToolUse", tool_name: "Bash",
  tool_input: Object.assign({ command, description }, toolCwd),
  tool_response: Object.assign({ stdout, stderr: "", interrupted: false, isImage: false }, extra),
};
const buf = Buffer.from(JSON.stringify(payload), "utf8");
fs.writeFileSync(out, buf);
process.stdout.write(String(buf.length));
JSEOF

# drive <payload-file> <delayMs|single> <tag>: hook stdout/stderr to $TMPD/<tag>.{out,err}.
drive() {
    run_with_timeout 30 node "$TMPD/chunked-writer.js" "$TMPW/$1" "$2" \
        | run_with_timeout 30 node "$RUN_TESTS_HOOK" >"$TMPD/$3.out" 2>"$TMPD/$3.err"
    DRIVE_RC="${PIPESTATUS[1]}"
}

# assert_recorded <tag> <sid> <want-failing-tests-json> <want-stdout|ANY-JSON>
# run_tests is seeded complete, so "pending" proves the hook recorded this run.
assert_recorded() {
    check "$1/hook-exit-0" "0" "$DRIVE_RC"
    check "$1/stderr-empty" "" "$(cat "$TMPD/$1.err")"
    if [ "$4" = "ANY-JSON" ]; then
        if run_with_timeout 10 node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$TMPW/$1.out" >/dev/null 2>&1; then
            pass "$1/stdout-is-hook-json"
        else
            fail "$1/stdout-is-hook-json" "stdout=$(cat "$TMPD/$1.out")"
        fi
    else
        check "$1/stdout" "$4" "$(cat "$TMPD/$1.out")"
    fi
    check "$1/run_tests-status" '"pending"' "$(step_field "$2" run_tests status)"
    check "$1/run_outcome" '"fail"' "$(step_field "$2" run_tests run_outcome)"
    check "$1/failing_tests" "$3" "$(step_field "$2" run_tests failing_tests)"
}

# assert_diagnostic <tag> <want-stderr>: fail-open + one diagnostic line, no state.
assert_diagnostic() {
    check "$1/hook-exit-0" "0" "$DRIVE_RC"
    check "$1/stdout-fail-open" "{}" "$(cat "$TMPD/$1.out")"
    check "$1/stderr-diagnostic" "$2" "$(cat "$TMPD/$1.err")"
    case "$(cat "$TMPD/$1.err")" in
        *SECRET-TOKEN*) fail "$1/stderr-hides-payload" ;;
        *) pass "$1/stderr-hides-payload" ;;
    esac
    check "$1/no-state-written" "" "$(ls -A "$TMPD/ws-$1")"
}

# ============================================================================
case_begin "worker-route-chunked-replay" "hooks/workflow-run-tests.js"
# ============================================================================
_sid1="f2479-ch1-$$"
seed_step "$_sid1" write_tests complete
seed_step "$_sid1" run_tests complete
_len1=$(run_with_timeout 30 node "$TMPD/build-payload.js" ch1 "$AGENTS_WIN" "$_sid1" "$TMPW/ch1.json" "$TMPW" 2>&1 || echo "build-failed")
if [ "$_len1" -gt 4096 ] 2>/dev/null; then pass "CH1/payload-exceeds-4096-bytes"
else fail "CH1/payload-exceeds-4096-bytes" "len=$_len1"; fi
_want1='['
for _i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15; do _want1+="\"tests/ch-$_i.sh\","; done
_want1="${_want1%,}]"
drive ch1.json 300 CH1
assert_recorded CH1 "$_sid1" "$_want1" ANY-JSON
case_end

# ============================================================================
case_begin "run-all-route-over-64k-chunked" "hooks/workflow-run-tests.js"
# ============================================================================
_sid2="f2479-ch2-$$"
seed_step "$_sid2" write_tests complete
seed_step "$_sid2" run_tests complete
_len2=$(run_with_timeout 30 node "$TMPD/build-payload.js" ch2 "$AGENTS_WIN" "$_sid2" "$TMPW/ch2.json" "$TMPW" 2>&1 || echo "build-failed")
if [ "$_len2" -gt 65536 ] 2>/dev/null; then pass "CH2/payload-exceeds-65536-bytes"
else fail "CH2/payload-exceeds-65536-bytes" "len=$_len2"; fi
drive ch2.json 300 CH2
assert_recorded CH2 "$_sid2" '["tests/a.sh","tests/b.sh"]' "{}"
case_end

# ============================================================================
case_begin "run-all-route-over-64k-single-write" "hooks/lib/read-stdin.js"
# ============================================================================
_sid3="f2479-ch3-$$"
seed_step "$_sid3" write_tests complete
seed_step "$_sid3" run_tests complete
run_with_timeout 30 node "$TMPD/build-payload.js" ch2 "$AGENTS_WIN" "$_sid3" "$TMPW/ch3.json" "$TMPW" >/dev/null 2>&1 || true
drive ch3.json single CH3
assert_recorded CH3 "$_sid3" '["tests/a.sh","tests/b.sh"]' "{}"
case_end

# ============================================================================
case_begin "stdin-json-invalid-diagnostic" "hooks/workflow-run-tests.js"
# ============================================================================
mkdir -p "$TMPD/ws-D1"
_d1='{"tool_name":"Bash","x":"SECRET-TOKEN-abc'
printf '%s' "$_d1" \
    | WORKFLOW_STATE_DIR="$TMPD/ws-D1" run_with_timeout 30 node "$RUN_TESTS_HOOK" >"$TMPD/D1.out" 2>"$TMPD/D1.err"
DRIVE_RC="${PIPESTATUS[1]}"
assert_diagnostic D1 "[workflow-run-tests] stdin json-invalid (${#_d1} bytes, SyntaxError): run_tests not recorded (fail-open)"
case_end

# ============================================================================
case_begin "stdin-empty-diagnostic" "hooks/workflow-run-tests.js"
# ============================================================================
mkdir -p "$TMPD/ws-D2"
WORKFLOW_STATE_DIR="$TMPD/ws-D2" run_with_timeout 30 node "$RUN_TESTS_HOOK" < /dev/null >"$TMPD/D2.out" 2>"$TMPD/D2.err"
DRIVE_RC=$?
assert_diagnostic D2 "[workflow-run-tests] stdin json-invalid (0 bytes, empty): run_tests not recorded (fail-open)"
case_end

# ============================================================================
case_begin "stdin-read-error-diagnostic" "hooks/workflow-run-tests.js"
# ============================================================================
mkdir -p "$TMPD/ws-D3"
WORKFLOW_STATE_DIR="$TMPD/ws-D3" run_with_timeout 30 node "$RUN_TESTS_HOOK" 0>"$TMPD/wo.txt" >"$TMPD/D3.out" 2>"$TMPD/D3.err"
DRIVE_RC=$?
assert_diagnostic D3 "[workflow-run-tests] stdin read-error (EBADF): run_tests not recorded (fail-open)"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
