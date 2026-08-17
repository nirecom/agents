#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-test-runner-behavior.sh
# Tests: bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch.js
# Tags: worker-dispatch, test-runner, status-derivation, parser, bounds, table-driven, TL2, scope:issue-specific

# Issue #1643 — the test-runner worker turns one suite invocation into a status,
# a failing-test list and a bounded log tail. The output-contract suite proves
# the SHAPE is well-formed; this file proves the values inside it are the right
# ones — that a failing suite is not reported as passing, that an empty
# failing_tests on a failure says why, and that both bounded lists really are
# bounded rather than merely usually short.

# The suite process is canned via tests/feature-1643-worker-dispatch-lib/
# spawn-stub.js: a real 15-failure / 100-line run cannot be produced on demand,
# and the parser is what is under test here, not bash.

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

# --- ambient sanitization (M-ambient), self-contained ------------------------

# The five RUN_ALL_* / FEATURE_644_PHASE knobs all change what the suite does,
# so a value inherited from the developer's shell could rewrite these verdicts.

# CAVEAT: GNU `env` stops parsing options at the first NAME=VALUE, so every
# `-u NAME` flag must precede every pass-through assignment. The array below is
# always splatted FIRST for exactly that reason; senv() is the same rule for
# call sites that do not already build an `env` invocation of their own.
AMBIENT_ENV_FLAGS=(-u RUN_ALL_JOBS -u RUN_ALL_DEADLINE -u RUN_ALL_PROGRESS
                   -u RUN_ALL_REAP -u FEATURE_644_PHASE)
AMBIENT_VARS="RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE"
senv() { env "${AMBIENT_ENV_FLAGS[@]}" "$@"; }
unset RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE

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
    DOUT="$(run_with_timeout 90 env "${AMBIENT_ENV_FLAGS[@]}" "WORKFLOW_PLANS_DIR=$PLANS" \
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
# Group 3 — test_args reach the suite verbatim, behind the worker's own lead argv
# ===========================================================================

# The worker owns two argv positions of its own (#1832): a `--deadline` derived
# from the caller's timeout budget, so the suite gives up before the worker does,
# and an optional `-j <n>` from the `jobs` payload field. Both sit AHEAD of
# test_args, which still reach the suite byte-for-byte and in order.
argv_of() {
    node -e '
const fs=require("fs");
let raw="";
try { raw=fs.readFileSync(process.argv[1],"utf8").trim(); } catch (e) { raw=""; }
if (raw === "") { process.stdout.write("(no spawn recorded)"); process.exit(0); }
let r=null;
try { r=JSON.parse(raw.split("\n")[0]); } catch (e) { r=null; }
process.stdout.write(r && Array.isArray(r.args) ? r.args.join(" ") : "(unparseable call log)");
' "$(nodepath "$CALLLOG")"
}

group_test_args() {
    local p
    p="$(write_payload tr-args "{\"cwd\":\"$MAIN\",\"test_args\":[\"tests/one.sh\",\"tests/two.sh\"],\"timeout_seconds\":30}")"
    set_run 0 "Results: PASS=2  FAIL=0  SKIP=0"
    dispatch_tr "$MAIN" "$p"
    assert_eq "args/status" "pass" "$(field_of status)"
    # max(30, 30 - 5) — the floor wins here, which is the point of having one.
    assert_eq "args/passed-through-verbatim" "--deadline 30 tests/one.sh tests/two.sh" \
        "$(argv_of)"
    assert_eq "args/script-is-run-all" "runAll" \
        "$(node -e '
const fs=require("fs");
const r=JSON.parse(fs.readFileSync(process.argv[1],"utf8").trim().split("\n")[0]);
process.stdout.write(String(r.script));
' "$(nodepath "$CALLLOG")")"

    p="$(write_payload tr-jobs "{\"cwd\":\"$MAIN\",\"test_args\":[\"tests/one.sh\"],\"timeout_seconds\":30,\"jobs\":1}")"
    set_run 0 "Results: PASS=1  FAIL=0  SKIP=0"
    dispatch_tr "$MAIN" "$p"
    assert_eq "args/jobs-becomes-dash-j" "--deadline 30 -j 1 tests/one.sh" "$(argv_of)"
}

# ===========================================================================
# Group 3b — argv boundaries survive the worker -> spawn hop byte-exactly
# ===========================================================================

# WHY (CPR-WPH): argv_of() joins the array with a space, so it cannot tell
# ["a b"] from ["a","b"] — exactly the confusion a spaced test_args entry
# causes. This group reads it element-wise (`argc=` plus one `argv[i]=<value>`
# line each), so a torn or merged boundary changes the recorded text. And spawn
# is shell:false: a glob, `$(...)`, a backtick or a `;` chain must arrive as the
# literal characters the caller wrote, never re-expanded on the way through.
argv_records() {
    node -e '
const fs=require("fs");
let raw="";
try { raw=fs.readFileSync(process.argv[1],"utf8").trim(); } catch (e) { raw=""; }
if (raw === "") { process.stdout.write("(no spawn recorded)"); process.exit(0); }
let r=null;
try { r=JSON.parse(raw.split("\n")[0]); } catch (e) { r=null; }
if (!r || !Array.isArray(r.args)) { process.stdout.write("(unparseable call log)"); process.exit(0); }
const n=Number(process.argv[2]);
const a=(n < 0) ? r.args : r.args.slice(Math.max(0, r.args.length - n));
process.stdout.write(["argc="+a.length].concat(a.map((v,i)=>"argv["+i+"]="+v)).join("\n"));
' "$(nodepath "$CALLLOG")" "$1"
}

# argv_block <~~-joined list> — expected record text from a table cell. `{SP}`
# is a literal space, so no cell relies on edge whitespace surviving the trim.
argv_block() {
    local rest="$1" item n=0 out=""
    WANT_N=0; WANT_BLOCK="argc=0"
    while :; do
        case "$rest" in
            *"~~"*) item="${rest%%~~*}"; rest="${rest#*~~}" ;;
            *) item="$rest"; rest="" ;;
        esac
        item="${item//\{SP\}/ }"
        out="$out
argv[$n]=$item"
        n=$((n + 1))
        [ -z "$rest" ] && break
    done
    WANT_N="$n"
    WANT_BLOCK="argc=$n$out"
}

group_argv_boundaries() {
    local name json want p got i=0
    while IFS='|' read -r name json want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="${name//[[:space:]]/}"
        json="$(printf '%s' "$json" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        want="$(printf '%s' "$want" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        argv_block "$want"
        i=$((i + 1))
        p="$(write_payload "tr-argv-$i" \
            "{\"cwd\":\"$MAIN\",\"test_args\":$json,\"timeout_seconds\":30}")"
        set_run 0 "Results: PASS=1  FAIL=0  SKIP=0"
        dispatch_tr "$MAIN" "$p"
        got="$(argv_records "$WANT_N")"
        assert_eq "argv/$name" "$WANT_BLOCK" "$got"
    done <<'TABLE'
space-in-filename    | ["tests/with space.sh"]                 | tests/with space.sh
space-in-dirname     | ["tests/dir with space/inner.sh"]       | tests/dir with space/inner.sh
two-separate-args    | ["tests/a.sh","tests/b.sh"]             | tests/a.sh~~tests/b.sh
adjacent-spaced-args | ["tests/a b.sh","tests/c d.sh"]         | tests/a b.sh~~tests/c d.sh
glob-stays-literal   | ["tests/multi-*.sh"]                    | tests/multi-*.sh
bare-star-literal    | ["*"]                                   | *
leading-space-arg    | [" tests/a.sh"]                         | {SP}tests/a.sh
trailing-space-arg   | ["tests/a.sh "]                         | tests/a.sh{SP}
cmdsubst-inert       | ["$(touch INJ_WD_A)"]                   | $(touch INJ_WD_A)
backtick-inert       | ["`touch INJ_WD_B`"]                    | `touch INJ_WD_B`
semicolon-chain      | ["tests/a.sh; touch INJ_WD_C"]          | tests/a.sh; touch INJ_WD_C
quote-inside-arg     | ["tests/it's here.sh"]                  | tests/it's here.sh
TABLE

    # The rows above read only the TAIL, staying honest about boundaries while
    # the worker's lead argv is still missing. This one pins the WHOLE array:
    # red until `--deadline` is prepended (#1832), and the row that catches a
    # lead which mangles the caller's arguments while inserting its own.
    p="$(write_payload tr-argv-full \
        "{\"cwd\":\"$MAIN\",\"test_args\":[\"tests/with space.sh\"],\"timeout_seconds\":30}")"
    set_run 0 "Results: PASS=1  FAIL=0  SKIP=0"
    dispatch_tr "$MAIN" "$p"
    assert_eq "argv/full-array-including-lead" \
        "argc=3
argv[0]=--deadline
argv[1]=30
argv[2]=tests/with space.sh" "$(argv_records -1)"

    # An EMPTY element never reaches argv: capability.js's rel-path-arg[] refuses
    # it before the worker is entered, so that boundary is settled upstream.
    p="$(write_payload tr-argv-empty \
        "{\"cwd\":\"$MAIN\",\"test_args\":[\"tests/a.sh\",\"\"],\"timeout_seconds\":30}")"
    set_run 0 "Results: PASS=1  FAIL=0  SKIP=0"
    dispatch_tr "$MAIN" "$p"
    got="$(field_of summary)"; case "$got" in *"must not be empty"*) got="refused-as-empty" ;; esac
    assert_eq "argv/empty-element-refused-before-spawn" \
        "runner-error|refused-as-empty|(no spawn recorded)" \
        "$(field_of status)|$got|$(argv_records -1)"

    # shell:false makes the metacharacter rows inert; a sentinel proves otherwise.
    assert_eq "argv/no-injection-sentinel-anywhere" "0" \
        "$(find "$TMPD" -name 'INJ_WD_*' 2>/dev/null | grep -c '' | tr -d ' ')"
}

# ===========================================================================
# Group 3c — ambient RUN_ALL_* / FEATURE_644_PHASE never reach the child
# ===========================================================================
group_ambient_sanitized() {
    local probe out want
    probe="$TMPD/ambient-probe.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'for v in %s WORKFLOW_PLANS_DIR; do printf "%%s=[%%s]\\n" "$v" "${!v-<unset>}"; done\n' \
            "$AMBIENT_VARS"
    } > "$probe"

    want="RUN_ALL_JOBS=[<unset>]
RUN_ALL_DEADLINE=[<unset>]
RUN_ALL_PROGRESS=[<unset>]
RUN_ALL_REAP=[<unset>]
FEATURE_644_PHASE=[<unset>]
WORKFLOW_PLANS_DIR=[$PLANS]"
    # Same funnel dispatch_tr uses, probe substituted for node: every `-u` flag
    # precedes every NAME=VALUE, because GNU env stops parsing options at the
    # first assignment and would otherwise treat `-u RUN_ALL_JOBS` as a command.
    out="$(
        export RUN_ALL_JOBS=99 RUN_ALL_DEADLINE=1 RUN_ALL_PROGRESS=verbose \
               RUN_ALL_REAP=off FEATURE_644_PHASE=6
        run_with_timeout 30 env "${AMBIENT_ENV_FLAGS[@]}" "WORKFLOW_PLANS_DIR=$PLANS" \
            bash "$probe" 2>&1
    )"
    assert_eq "ambient/hostile-values-never-reach-the-child" "$want" "$out"

    # And the verdict itself is indifferent to them.
    export RUN_ALL_JOBS=99 RUN_ALL_DEADLINE=1 RUN_ALL_PROGRESS=verbose \
           RUN_ALL_REAP=off FEATURE_644_PHASE=6
    set_run 0 "Results: PASS=3  FAIL=0  SKIP=1"
    dispatch_tr "$MAIN" "$PAYLOAD"
    assert_eq "ambient/verdict-unchanged-under-hostile-ambient" \
        "pass|PASS=3 FAIL=0 SKIP=1" "$(field_of status)|$(field_of summary)"
    unset RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE
}

# ===========================================================================
# Group 4 — CONTRACT_LINE_RE, table-driven
# ===========================================================================

# WHY (CPR-WPH): CONTRACT_LINE_RE is the one regex whose verdict the commit gate
# ultimately trusts, and it is applied to stdout and stderr CONCATENATED, after
# CRLF normalisation and blank-line removal. A single happy-path example proves
# none of that. The table below is the matching/non-matching matrix required by
# skills/_shared/test-design/parser-regex-tests.md.

# Each row drives the REAL pipeline (stub suite -> worker -> renderer), so what
# is asserted is what a caller would actually receive: the rendered contract
# value, or `(none)` when the worker refused to report one.
set_run_streams() {
    node -e '
const fs = require("fs");
const un = (s) => String(s).replace(/\\r/g, "\r").replace(/\\t/g, "\t").replace(/\\n/g, "\n");
fs.writeFileSync(process.argv[1], JSON.stringify([{
  status: Number(process.argv[2]), stdout: un(process.argv[3]), stderr: un(process.argv[4]),
}]));
' "$(nodepath "$CANNED")" "$1" "$2" "$3"
}

# Only the VALUE is read back, never the whole payload: re-printing the
# dispatcher's stdout would put a second contract-shaped line into this file's
# own output and trip the run-tests hook's exactly-one rule.
contract_of() {
    local v
    v="$(printf '%s\n' "$DOUT" | sed -n 's/^RUN_CONTRACT: //p' | head -1)"
    [ -z "$v" ] && v="(none)"
    printf '%s' "$v"
}

group_contract_regex_table() {
    local name so se want got
    while IFS='|' read -r name so se want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="${name//[[:space:]]/}"
        want="$(printf '%s' "$want" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        set_run_streams 0 "$so" "$se"
        dispatch_tr "$MAIN" "$PAYLOAD"
        got="$(contract_of)"
        assert_eq "contract-re/$name" "$want" "$got"
    done <<'TABLE'
zero-lines            | Results: PASS=1  FAIL=0  SKIP=0                   |                                                   | (none)
exactly-one           | RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1     |                                                   | PASS=1 FAIL=0 SKIP=0 EXECUTED=1
duplicate-identical   | RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1\nRUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 |               | (none)
duplicate-different   | RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1\nRUN_CONTRACT: PASS=9 FAIL=0 SKIP=0 EXECUTED=9 |               | (none)
missing-field         | RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0               |                                                   | (none)
non-numeric-pass      | RUN_CONTRACT: PASS=x FAIL=0 SKIP=0 EXECUTED=1     |                                                   | (none)
negative-pass         | RUN_CONTRACT: PASS=-1 FAIL=0 SKIP=0 EXECUTED=1    |                                                   | (none)
reordered-fields      | RUN_CONTRACT: FAIL=0 PASS=1 SKIP=0 EXECUTED=1     |                                                   | (none)
comma-separator       | RUN_CONTRACT: PASS=1, FAIL=0, SKIP=0, EXECUTED=1  |                                                   | (none)
double-space-between  | RUN_CONTRACT: PASS=1  FAIL=0 SKIP=0 EXECUTED=1    |                                                   | (none)
lowercase-keyword     | run_contract: PASS=1 FAIL=0 SKIP=0 EXECUTED=1     |                                                   | (none)
embedded-mid-line     | echo RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1|                                                   | (none)
crlf-line-ending      | RUN_CONTRACT: PASS=2 FAIL=0 SKIP=0 EXECUTED=2\r\nResults: PASS=2  FAIL=0  SKIP=0 |                    | PASS=2 FAIL=0 SKIP=0 EXECUTED=2
lone-cr-after-fields  | RUN_CONTRACT: PASS=2 FAIL=0 SKIP=0 EXECUTED=2\rtrailing                          |                    | PASS=2 FAIL=0 SKIP=0 EXECUTED=2
leading-spaces        |     RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3 |                                                   | PASS=3 FAIL=0 SKIP=0 EXECUTED=3
leading-tab           | \tRUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3   |                                                   | PASS=3 FAIL=0 SKIP=0 EXECUTED=3
leading-mixed-ws      | \t  \tRUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3 |                                                 | PASS=3 FAIL=0 SKIP=0 EXECUTED=3
leading-nbsp-like     | . RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3   |                                                   | (none)
trailing-extra-field  | RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 EXTRA=9 |                                               | PASS=1 FAIL=0 SKIP=0 EXECUTED=1
leading-zeros         | RUN_CONTRACT: PASS=007 FAIL=0 SKIP=0 EXECUTED=007 |                                                   | PASS=7 FAIL=0 SKIP=0 EXECUTED=7
stderr-only           | Results: PASS=1  FAIL=0  SKIP=0                   | RUN_CONTRACT: PASS=4 FAIL=0 SKIP=0 EXECUTED=4     | PASS=4 FAIL=0 SKIP=0 EXECUTED=4
one-per-stream        | RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1     | RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1     | (none)
blank-output          |                                                   |                                                   | (none)
TABLE
}

group_pass
group_fail
group_parse_degraded
group_timeout
group_runner_error
group_bounds
group_test_args
group_argv_boundaries
group_ambient_sanitized
group_contract_regex_table

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
