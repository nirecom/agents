#!/usr/bin/env bash
# tests/feature-1832-run-all-parallel/k-dispatcher-jobs.sh
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, worker-dispatch, capability, security, TL1, scope:issue-specific
# Serial: timing-sensitive parallelism measurements must not compete with other tests

# WHY: the run-tests worker owns a deadline, so it needs to tune the dispatched
# suite's parallelism. Adds int-typed, range-bounded `jobs` payload field ->
# `-j <n>` (or `-j auto` when absent); capability.js walls it off from free text.

# RED-FIRST: `jobs` isn't in the registry yet, so rejection rows are green now
# (regression fence); the behavioural rows (serialisation, overlap, argv) are the
# intended failures.

# ISOLATION: throwaway git family (temp main + linked worktree). HOME is pinned
# because RUN_ALL_CACHE_DIR isn't in the dispatcher's child env allowlist.

# TL3 gap: real wall-clock speedup and deadline reachability on a CI host —
# tests/TL3-worker-dispatch-run-tests.sh is the gated tier.

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not found"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
REAL_RUNNER="$AGENTS_DIR/tests/run-all.sh"
REAL_LIB="$AGENTS_DIR/bin/lib/run-all-parallelism.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() { local s="$1"; shift; bash "$AGENTS_DIR/bin/run-with-timeout.sh" "$s" "$@"; }

if [ ! -f "$DISPATCH_JS" ] || [ ! -f "$REAL_RUNNER" ]; then
    fail "k-jobs/prerequisites" "dispatcher=$DISPATCH_JS runner=$REAL_RUNNER"
    echo ""; echo "Total: PASS=$PASS FAIL=$FAIL"; exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ra-k-$$")"
mkdir -p "$TMPD"
cleanup() { git -C "$MAIN_RAW" worktree remove --force "$LINKED_RAW" >/dev/null 2>&1 || true; rm -rf "$TMPD"; }
trap cleanup EXIT

nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

# --- fixture isolation (rules/test/fixture-isolation.md) --------------------
export CLAUDE_WORKFLOW_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
export RUN_ALL_CACHE_DIR="$TMPD/cache"
mkdir -p "$RUN_ALL_CACHE_DIR"
FIX_HOME="$TMPD/home"; mkdir -p "$FIX_HOME/.claude"

# --- git family fixture -----------------------------------------------------
MAIN_RAW="$TMPD/mainrepo"
LINKED_RAW="$TMPD/linked-wt"
mkdir -p "$MAIN_RAW"
git -C "$MAIN_RAW" init -q -b main
git -C "$MAIN_RAW" config user.email "test@example.com"
git -C "$MAIN_RAW" config user.name "Test"
git -C "$MAIN_RAW" config core.hooksPath /dev/null
echo init > "$MAIN_RAW/README.md"
git -C "$MAIN_RAW" add README.md >/dev/null 2>&1
git -C "$MAIN_RAW" commit -q --no-verify -m initial >/dev/null 2>&1
git -C "$MAIN_RAW" worktree add -q -b feature/jobs-probe "$LINKED_RAW" >/dev/null 2>&1
if [ ! -d "$LINKED_RAW" ]; then
    fail "k-jobs/fixture/linked-worktree" "git worktree add failed"
    echo ""; echo "Total: PASS=$PASS FAIL=$FAIL"; exit 1
fi
MAIN="$(nodepath "$MAIN_RAW")"
LINKED="$(nodepath "$LINKED_RAW")"
PLANS="$(nodepath "$WORKFLOW_PLANS_DIR")"

# --- the runner under the linked worktree -----------------------------------
# A faithful `cp` of the real runner, reached through a one-line wrapper that
# records the argv the worker chose. The real tests/run-all.sh is never edited,
# and the wrapper adds no behaviour of its own beyond the log line.
ARGV_LOG="$TMPD/argv.log"
RUN_LOG="$TMPD/run.log"
: > "$ARGV_LOG"
: > "$RUN_LOG"
mkdir -p "$LINKED_RAW/tests" "$LINKED_RAW/bin/lib"
cp "$REAL_RUNNER" "$LINKED_RAW/tests/.real-run-all.sh"
[ -f "$REAL_LIB" ] && cp "$REAL_LIB" "$LINKED_RAW/bin/lib/run-all-parallelism.sh"
{
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >> %s\n' "\"$ARGV_LOG\""
    printf 'exec bash %s "$@"\n' "\"$LINKED_RAW/tests/.real-run-all.sh\""
} > "$LINKED_RAW/tests/run-all.sh"

# Four equal-cost dummies that bracket their own execution in a shared log.
# Serial execution can only ever produce S1 E1 S2 E2 ...; two S lines in a row is
# proof that two of them were alive at the same moment.
for n in 1 2 3 4; do
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Tests: tests/run-all.sh\n'
        printf '# Tags: fixture, scope:issue-specific\n'
        printf 'printf "S%%s\\n" %s >> %s\n' "$n" "\"$RUN_LOG\""
        printf 'sleep 1\n'
        printf 'printf "E%%s\\n" %s >> %s\n' "$n" "\"$RUN_LOG\""
        printf 'exit 0\n'
    } > "$LINKED_RAW/tests/d$n.sh"
done
TEST_ARGS='"tests/d1.sh","tests/d2.sh","tests/d3.sh","tests/d4.sh"'

# --- drivers ----------------------------------------------------------------
DOUT=""
DRC=0
# dispatch <payload-basename> <payload-json>
dispatch() {
    local base="$1" json="$2" pfile
    pfile="$WORKFLOW_PLANS_DIR/$base.json"
    printf '%s' "$json" > "$pfile"
    : > "$ARGV_LOG"
    : > "$RUN_LOG"
    DRC=0
    DOUT="$(run_with_timeout 120 env "HOME=$FIX_HOME" "WORKFLOW_PLANS_DIR=$PLANS" \
        node "$DISPATCH_JS" test-runner "$MAIN" "$(nodepath "$pfile")" 2>&1)" || DRC=$?
}
# Number of adjacent "two starts in a row" pairs in the shared log.
overlaps() { awk '{c=substr($0,1,1); if (c=="S" && p=="S") n++; p=c} END {print n+0}' "$RUN_LOG"; }
started()  { grep -c '^S' "$RUN_LOG" 2>/dev/null || true; }
argv_line() { head -1 "$ARGV_LOG" 2>/dev/null || true; }
yaml_field() { printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1; }

# ===========================================================================
# 1. jobs:1 — an explicit request for serial execution must be obeyed
# ===========================================================================
case_jobs_one() {
    dispatch "j1" "{\"cwd\":\"$LINKED\",\"test_args\":[$TEST_ARGS],\"timeout_seconds\":60,\"jobs\":1}"
    # Without this row "no overlap" would pass on a run where nothing executed.
    assert_eq "k-jobs/j1/all-four-ran" "4" "$(started)"
    assert_eq "k-jobs/j1/no-overlap" "0" "$(overlaps)"
    case " $(argv_line) " in
        *" -j 1 "*) pass "k-jobs/j1/argv-carries-j-1" ;;
        *) fail "k-jobs/j1/argv-carries-j-1" "the worker did not pass '-j 1' to tests/run-all.sh" ;;
    esac
}

# ===========================================================================
# 2. jobs:4 — the same corpus must actually overlap
# ===========================================================================
case_jobs_four() {
    dispatch "j4" "{\"cwd\":\"$LINKED\",\"test_args\":[$TEST_ARGS],\"timeout_seconds\":60,\"jobs\":4}"
    assert_eq "k-jobs/j4/all-four-ran" "4" "$(started)"
    if [ "$(overlaps)" -ge 1 ]; then pass "k-jobs/j4/overlap-observed"
    else fail "k-jobs/j4/overlap-observed" \
        "jobs:4 produced a strictly serial S/E sequence — nothing ran concurrently"; fi
    case " $(argv_line) " in
        *" -j 4 "*) pass "k-jobs/j4/argv-carries-j-4" ;;
        *) fail "k-jobs/j4/argv-carries-j-4" "the worker did not pass '-j 4' to tests/run-all.sh" ;;
    esac
}

# ===========================================================================
# 3. jobs omitted — `-j auto`, a deadline below the worker's budget, and an
#    otherwise unchanged output contract
# ===========================================================================
case_jobs_omitted() {
    local line
    dispatch "auto" "{\"cwd\":\"$LINKED\",\"test_args\":[$TEST_ARGS],\"timeout_seconds\":60}"
    line=" $(argv_line) "
    assert_eq "k-jobs/auto/dispatcher-exit-zero" "0" "$DRC"
    assert_eq "k-jobs/auto/status-pass" "pass" "$(yaml_field status)"
    assert_eq "k-jobs/auto/exit-code-zero" "0" "$(yaml_field exit_code)"
    assert_eq "k-jobs/auto/all-four-ran" "4" "$(started)"
    if printf '%s\n' "$DOUT" | grep -qE '^RUN_CONTRACT: PASS=4 FAIL=0 SKIP=0 EXECUTED=4$'; then
        pass "k-jobs/auto/contract-rendered"
    else fail "k-jobs/auto/contract-rendered" \
        "the worker did not render 'RUN_CONTRACT: PASS=4 FAIL=0 SKIP=0 EXECUTED=4'"; fi
    # An absent `jobs` is a deferral, not a number: the worker adds no -j and the
    # suite resolves `auto` itself (no cache here, so the conservative 4).
    case "$line" in
        *" -j "*) fail "k-jobs/auto/argv-omits-explicit-jobs" \
                       "an absent jobs field must not be turned into a concrete -j <n>" ;;
        *) pass "k-jobs/auto/argv-omits-explicit-jobs" ;;
    esac
    if [ "$(overlaps)" -ge 1 ]; then pass "k-jobs/auto/auto-still-runs-in-parallel"
    else fail "k-jobs/auto/auto-still-runs-in-parallel" \
        "with no jobs field the suite must still resolve auto to a parallel width"; fi
    # max(30, 60 - 5): the suite must give up before the worker's own budget does.
    case "$line" in
        *" --deadline 55 "*) pass "k-jobs/auto/argv-carries-deadline" ;;
        *) fail "k-jobs/auto/argv-carries-deadline" \
               "expected '--deadline 55' from timeout_seconds=60" ;;
    esac
}

# ===========================================================================
# 4. Out-of-domain jobs values are rejected by capability.js, and the rejection
#    happens BEFORE anything is executed.
# ===========================================================================
case_rejections() {
    local name json
    while IFS='|' read -r name json; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"
        dispatch "reject-$name" "{\"cwd\":\"$LINKED\",\"test_args\":[$TEST_ARGS],\"timeout_seconds\":60,$json}"
        assert_eq "k-jobs/reject/$name/status-runner-error" "runner-error" "$(yaml_field status)"
        assert_eq "k-jobs/reject/$name/exit-code-minus-one" "-1" "$(yaml_field exit_code)"
        assert_eq "k-jobs/reject/$name/dispatcher-exit-zero" "0" "$DRC"
        assert_eq "k-jobs/reject/$name/runner-never-started" "0" \
            "$(wc -l < "$ARGV_LOG" | tr -d ' ')"
        assert_eq "k-jobs/reject/$name/no-test-executed" "0" "$(started)"
        # Which wall rejects moves once `jobs` is declared (structure accepts the
        # key, capability rejects the value), so the assertion is on the two
        # invariants that do not move: a wall said no, and it named the field.
        if printf '%s\n' "$DOUT" | grep -qE "^summary: .*(capability|payload):" \
            && printf '%s\n' "$DOUT" | grep -q 'jobs'; then
            pass "k-jobs/reject/$name/rejection-names-the-jobs-field"
        else fail "k-jobs/reject/$name/rejection-names-the-jobs-field" \
            "the rejection summary must come from a validation wall and name 'jobs'"; fi
    done <<TABLE
jobs-zero   | "jobs":0
jobs-string | "jobs":"4"
jobs-huge   | "jobs":99999
jobs-float  | "jobs":2.5
TABLE
}

case_jobs_one
case_jobs_four
case_jobs_omitted
case_rejections

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
