#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-test-runner-behavior.sh
# Tests: bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch.js
# Tags: worker-dispatch, test-runner, status-derivation, parser, bounds, table-driven, TL2, scope:issue-specific
#
# Issue #1643 — the test-runner worker turns one suite invocation into a status,
# a failing-test list and a bounded log tail. The output-contract suite proves
# the SHAPE is well-formed; this file proves the values inside it are the right
# ones — that a failing suite is not reported as passing, that an empty
# failing_tests on a failure says why, and that both bounded lists really are
# bounded rather than merely usually short.
#
# The suite process is canned via tests/feature-1643-worker-dispatch-lib/
# spawn-stub.js: a real 15-failure / 100-line run cannot be produced on demand,
# and the parser is what is under test here, not bash.
#
# TL3 gap (what this TL2 test does NOT catch):
#   - The real tests/run-all.sh output format drifting away from
#     `FAIL: <script> (exit N)` / `Results: ...`. Only a real suite run shows
#     that; tests/TL3-worker-dispatch-run-tests.sh is the gated tier for it.
#   - A real OS-level timeout kill (SIGTERM handling by spawnSync).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1643_TR_INNER:-}" ]; then
    _WD1643_TR_INNER=1 timeout 420 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
PRELOAD="$AGENTS_DIR/tests/feature-1643-worker-dispatch-lib/spawn-stub.js"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
assert_has() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) pass "$name" ;;
        *) fail "$name" "want substring '$needle' in '$hay'" ;;
    esac
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

if [ ! -f "$DISPATCH_JS" ] || [ ! -f "$PRELOAD" ]; then
    fail "0: fixture prerequisites missing" "dispatcher=$DISPATCH_JS stub=$PRELOAD"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-tr-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

mk_repo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q -b main
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "Test"
    git -C "$d" config core.hooksPath /dev/null
    echo init > "$d/README.md"
    git -C "$d" add README.md >/dev/null 2>&1
    git -C "$d" commit -q --no-verify -m initial >/dev/null 2>&1
}

MAIN_RAW="$TMPD/mainrepo"; mk_repo "$MAIN_RAW"
mkdir -p "$MAIN_RAW/tests"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MAIN_RAW/tests/run-all.sh"
# Second repo deliberately WITHOUT tests/run-all.sh — the runner-error branch.
BARE_RAW="$TMPD/barerepo"; mk_repo "$BARE_RAW"

PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
MAIN="$(nodepath "$MAIN_RAW")"
BARE="$(nodepath "$BARE_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"
CANNED="$TMPD/canned.json"
CALLLOG="$TMPD/calls.jsonl"

DOUT=""; DRC=0
write_payload() { printf '%s' "$2" > "$PLANS_RAW/$1.json"; nodepath "$PLANS_RAW/$1.json"; }
field_of() {
    local v
    v="$(printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1)"
    v="${v%\'}"; v="${v#\'}"
    printf '%s' "$v"
}
# Rules JSON is built by node so multi-line stdout survives intact.
dispatch_tr() {
    local root="$1" pfile="$2"
    : > "$CALLLOG"
    DRC=0
    DOUT="$(run_with_timeout 90 env "WORKFLOW_PLANS_DIR=$PLANS" \
        "WD_SPAWN_MODULE=$(nodepath "$AGENTS_DIR/bin/worker-dispatch/spawn.js")" \
        "WD_CANNED=$(nodepath "$CANNED")" \
        "WD_CALL_LOG=$(nodepath "$CALLLOG")" \
        node -r "$(nodepath "$PRELOAD")" "$(nodepath "$DISPATCH_JS")" test-runner "$root" "$pfile" 2>/dev/null)" || DRC=$?
}
# set_run <exit-status> <line>... — writes the canned suite output.
set_run() {
    local status="$1"; shift
    node -e '
const fs=require("fs");
const status=Number(process.argv[2]);
const stdout=process.argv.slice(3).join("\n")+"\n";
fs.writeFileSync(process.argv[1], JSON.stringify([{status, stdout}]));
' "$(nodepath "$CANNED")" "$status" "$@"
}
set_timeout_run() {
    printf '%s' '[{"timedOut":true,"status":null,"stdout":"partial output line\n"}]' > "$CANNED"
}
tail_lines() { printf '%s\n' "$DOUT" | sed -n '/^log_tail: |$/,$p' | tail -n +2 | grep -c '' | tr -d ' '; }
failing_count() { printf '%s\n' "$DOUT" | grep -c '^  - ' | tr -d ' '; }

PAYLOAD="$(write_payload tr-main "{\"cwd\":\"$MAIN\",\"timeout_seconds\":30}")"

# ===========================================================================
# Group 1 — status derivation
# ===========================================================================
group_pass() {
    set_run 0 "Results: PASS=3  FAIL=0  SKIP=1"
    dispatch_tr "$MAIN" "$PAYLOAD"
    assert_eq "pass/exit0" "0" "$DRC"
    assert_eq "pass/status" "pass" "$(field_of status)"
    assert_eq "pass/exit-code" "0" "$(field_of exit_code)"
    # The worker reports what the suite itself said, not a re-count of its own.
    assert_eq "pass/summary-carries-the-results-tally" "PASS=3 FAIL=0 SKIP=1" "$(field_of summary)"
    assert_eq "pass/failing-tests-empty" "[]" "$(field_of failing_tests)"
}

group_fail() {
    set_run 1 "FAIL: tests/alpha.sh (exit 1)" "FAIL: tests/beta.sh (exit 3)" "Results: PASS=1  FAIL=2  SKIP=0"
    dispatch_tr "$MAIN" "$PAYLOAD"
    assert_eq "fail/exit0" "0" "$DRC"
    assert_eq "fail/status" "fail" "$(field_of status)"
    assert_eq "fail/exit-code" "1" "$(field_of exit_code)"
    assert_eq "fail/failing-tests-listed" "2" "$(failing_count)"
    assert_has "fail/names-the-first-suite" "tests/alpha.sh" "$DOUT"
    assert_has "fail/names-the-second-suite" "tests/beta.sh" "$DOUT"
}

# A failing suite that yields no parseable FAIL lines must SAY so — a bare
# `failing_tests: []` next to `status: fail` reads as "nothing failed".
group_parse_degraded() {
    set_run 1 "something went wrong" "Results: PASS=0  FAIL=1  SKIP=0"
    dispatch_tr "$MAIN" "$PAYLOAD"
    assert_eq "degraded/status" "fail" "$(field_of status)"
    assert_eq "degraded/failing-tests-empty" "[]" "$(field_of failing_tests)"
    assert_has "degraded/summary-explains-the-empty-list" "parse-degraded" "$(field_of summary)"
}

group_timeout() {
    local p
    p="$(write_payload tr-to "{\"cwd\":\"$MAIN\",\"timeout_seconds\":7}")"
    set_timeout_run
    dispatch_tr "$MAIN" "$p"
    assert_eq "timeout/exit0" "0" "$DRC"
    assert_eq "timeout/status" "timeout" "$(field_of status)"
    assert_eq "timeout/exit-code-is-minus-one" "-1" "$(field_of exit_code)"
    assert_has "timeout/summary-names-the-budget" "7s budget" "$(field_of summary)"
}

group_runner_error() {
    local p
    p="$(write_payload tr-bare "{\"cwd\":\"$BARE\",\"timeout_seconds\":30}")"
    set_run 0 "never reached"
    dispatch_tr "$BARE" "$p"
    assert_eq "runnererr/exit0" "0" "$DRC"
    assert_eq "runnererr/status" "runner-error" "$(field_of status)"
    assert_eq "runnererr/exit-code-is-minus-one" "-1" "$(field_of exit_code)"
    assert_has "runnererr/summary-names-the-missing-script" "tests/run-all.sh" "$(field_of summary)"
    # Nothing may be spawned when the script does not exist.
    assert_eq "runnererr/no-process-started" "0" "$(grep -c '' "$CALLLOG" | tr -d ' ')"
}

# ===========================================================================
# Group 2 — the bounded lists are actually bounded
# ===========================================================================
group_bounds() {
    local args=() i
    for i in $(seq 1 15); do args+=("FAIL: tests/s$i.sh (exit 1)"); done
    for i in $(seq 1 100); do args+=("log line $i"); done
    args+=("Results: PASS=0  FAIL=15  SKIP=0")
    set_run 1 "${args[@]}"
    dispatch_tr "$MAIN" "$PAYLOAD"
    assert_eq "bounds/status" "fail" "$(field_of status)"
    assert_eq "bounds/failing-tests-capped-at-10" "10" "$(failing_count)"
    assert_eq "bounds/log-tail-capped-at-40" "40" "$(tail_lines)"
    # The tail is the END of the output, so the Results line must be in it and
    # the very first log line must not.
    assert_has "bounds/tail-keeps-the-last-lines" "Results: PASS=0  FAIL=15  SKIP=0" "$DOUT"
    if printf '%s\n' "$DOUT" | grep -qE '^  log line 1$'; then
        fail "bounds/tail-drops-the-oldest-lines" "line 1 of 100 survived a 40-line tail"
    else
        pass "bounds/tail-drops-the-oldest-lines"
    fi
}

# ===========================================================================
# Group 3 — test_args reach the suite verbatim
# ===========================================================================
group_test_args() {
    local p
    p="$(write_payload tr-args "{\"cwd\":\"$MAIN\",\"test_args\":[\"tests/one.sh\",\"tests/two.sh\"],\"timeout_seconds\":30}")"
    set_run 0 "Results: PASS=2  FAIL=0  SKIP=0"
    dispatch_tr "$MAIN" "$p"
    assert_eq "args/status" "pass" "$(field_of status)"
    assert_eq "args/passed-through-verbatim" "tests/one.sh tests/two.sh" \
        "$(node -e '
const fs=require("fs");
const r=JSON.parse(fs.readFileSync(process.argv[1],"utf8").trim().split("\n")[0]);
process.stdout.write(r.args.join(" "));
' "$(nodepath "$CALLLOG")")"
    assert_eq "args/script-is-run-all" "runAll" \
        "$(node -e '
const fs=require("fs");
const r=JSON.parse(fs.readFileSync(process.argv[1],"utf8").trim().split("\n")[0]);
process.stdout.write(String(r.script));
' "$(nodepath "$CALLLOG")")"
}

group_pass
group_fail
group_parse_degraded
group_timeout
group_runner_error
group_bounds
group_test_args

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
