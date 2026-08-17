#!/usr/bin/env bash
# tests/feature-1832-run-all-parallel/i-hook-contract-integration.sh
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, hook, contract, security, TL2, scope:issue-specific
# Serial: timing-sensitive parallelism measurements must not compete with other tests

# WHY (CPR-WPH): invariant 2 says the parallel runner must keep marking run_tests
# complete through hooks/workflow-run-tests.js. That hook does not merely look for a
# RUN_CONTRACT line — it requires EXACTLY ONE in the whole of stdout, with nothing
# but whitespace after it (stdoutAttributed, #1273 round 5). Serialised output made
# that easy to satisfy by accident. A parallel runner replays child output verbatim,
# so any test that prints a contract-shaped line now lands in the parent's stdout
# and destroys the run's completion — a defect the current serial runner already
# has, which parallelism only makes louder.

# The fix under test is structural, in the parent: neutralize_stream rewrites any
# child line matching the contract shape before replay, on BOTH stdout and stderr.
# This file verifies the end of that chain against the real hook process rather
# than a re-implementation of its rules, and fences it from the other side with two
# counter-proofs that must NOT complete.

# RED-FIRST: the parallel surface does not exist yet, so the positive row reports a
# demotion instead of `complete`. The two counter-proof rows are green today and
# stay green after the fix — they are regression fences, not evidence of the bug.

# ISOLATION: CLAUDE_WORKFLOW_DIR / WORKFLOW_PLANS_DIR are dual-pinned, the session
# ids are fixtures, TESTS_DIR is a fixture and every invocation passes explicit
# fixture positional arguments. Captured runner output is never echoed to this
# script's own stdout — a replayed contract line would corrupt the parent suite.

# TL3 gap (what this TL2 test does NOT catch): whether a real Claude Code Bash tool
# call delivers this stdout unmodified to the hook. tests/TL3-worker-dispatch-run-tests.sh
# is the gated tier for the real-invocation shape. Closest-to-action mitigation:
# bin/check-verification-gate.sh at WORKFLOW_USER_VERIFIED preflight (category:
# hook-registration).

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
AGENTS_WIN="$(nodepath "$AGENTS_DIR")"
RUNNER="$AGENTS_DIR/tests/run-all.sh"
HOOK="$AGENTS_DIR/hooks/workflow-run-tests.js"
STATE_MOD="$AGENTS_WIN/hooks/workflow-state"

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

if [ ! -f "$HOOK" ] || [ ! -f "$RUNNER" ]; then
    fail "i-hook/prerequisites" "hook=$HOOK runner=$RUNNER"
    echo ""; echo "Total: PASS=$PASS FAIL=$FAIL"; exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ra-hook-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# --- fixture isolation (rules/test/fixture-isolation.md) --------------------
export CLAUDE_WORKFLOW_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/workflow-plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
export RUN_ALL_CACHE_DIR="$TMPD/cache"
mkdir -p "$RUN_ALL_CACHE_DIR"

# --- fixture corpus ---------------------------------------------------------
# Three of the four dummies print a contract-SHAPED line, in each of the three
# spellings the parser tolerates: bare on stdout, on stderr, and leading-whitespace
# indented. All four pass, so a correctly neutralising runner yields FAIL=0.
FX="$TMPD/fx"; mkdir -p "$FX"
printf '#!/usr/bin/env bash\necho "t1 ok"\nexit 0\n' > "$FX/t1.sh"
printf '#!/usr/bin/env bash\necho "RUN_CONTRACT: PASS=99 FAIL=0 SKIP=0 EXECUTED=99"\nexit 0\n' > "$FX/t2.sh"
printf '#!/usr/bin/env bash\necho "RUN_CONTRACT: PASS=98 FAIL=0 SKIP=0 EXECUTED=98" >&2\nexit 0\n' > "$FX/t3.sh"
printf '#!/usr/bin/env bash\necho "   RUN_CONTRACT: PASS=97 FAIL=0 SKIP=0 EXECUTED=97"\nexit 0\n' > "$FX/t4.sh"
FX_WIN="$(nodepath "$FX")"
FX_ARGS="$FX_WIN/t1.sh $FX_WIN/t2.sh $FX_WIN/t3.sh $FX_WIN/t4.sh"

# The command string the hook is told about. It names the REAL tests/run-all.sh so
# provenance-identity.js can verify the emitter by realpath; only TESTS_DIR and the
# positional arguments point at the fixture.
RUNALL_CMD="bash $AGENTS_WIN/tests/run-all.sh -j 4 $FX_ARGS"

# --- drivers ----------------------------------------------------------------
runner_fingerprint() { wc -c < "$RUNNER" | tr -d ' '; }
RUNNER_FINGERPRINT="$(runner_fingerprint)"

contract_count() {
    printf '%s\n' "$1" | grep -cE '^[[:space:]]*RUN_CONTRACT: PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+ EXECUTED=[0-9]+' || true
}
# last_nonempty_is_contract <text> → yes | no
last_nonempty_is_contract() {
    local last
    last="$(printf '%s\n' "$1" | grep -vE '^[[:space:]]*$' | tail -1)"
    case "$last" in
        RUN_CONTRACT:\ PASS=*) printf 'yes' ;;
        *) printf 'no' ;;
    esac
}
seed_step() {
    run_with_timeout 30 node -e "require('$STATE_MOD').markStep(process.argv[1], process.argv[2], process.argv[3]);" \
        "$1" "$2" "$3" >/dev/null 2>&1 || true
}
run_tests_status() {
    run_with_timeout 30 node -e "
try {
  const s = require('$STATE_MOD').readState(process.argv[1]);
  console.log(s && s.steps && s.steps.run_tests ? s.steps.run_tests.status : 'absent');
} catch (e) { console.log('absent'); }
" "$1" 2>/dev/null || echo "absent"
}
# drive_hook <command> <exit_code> <sid> <stdout-file> → hook stdout JSON
drive_hook() {
    run_with_timeout 30 node -e "
const fs = require('fs');
process.stdout.write(JSON.stringify({
  tool_name: 'Bash',
  tool_input: { command: process.argv[1], cwd: process.argv[5] },
  tool_response: { exit_code: parseInt(process.argv[2], 10), stdout: fs.readFileSync(process.argv[4], 'utf8') },
  session_id: process.argv[3]
}));
" "$1" "$2" "$3" "$4" "$AGENTS_WIN" 2>/dev/null \
        | run_with_timeout 30 node "$HOOK" 2>/dev/null || true
}

# ===========================================================================
# 1. The positive path — a parallel run still completes run_tests
# ===========================================================================
OUT_MAIN="$TMPD/main-stdout.txt"
RC_MAIN=0
case_complete() {
    local sid="1832iiii-0000-4000-8000-000000000001" out status
    run_with_timeout 120 env "TESTS_DIR=$FX" "RUN_ALL_CACHE_DIR=$RUN_ALL_CACHE_DIR" \
        bash "$RUNNER" -j 4 "$FX/t1.sh" "$FX/t2.sh" "$FX/t3.sh" "$FX/t4.sh" \
        > "$OUT_MAIN" 2>"$TMPD/main-stderr.txt" || RC_MAIN=$?
    out="$(cat "$OUT_MAIN")"

    assert_eq "i-hook/run/exit-zero" "0" "$RC_MAIN"
    assert_eq "i-hook/run/exactly-one-contract-in-stdout" "1" "$(contract_count "$out")"
    assert_eq "i-hook/run/contract-is-last-non-empty-line" "yes" "$(last_nonempty_is_contract "$out")"
    case "$out" in
        *"RUN_CONTRACT: PASS=4 FAIL=0 SKIP=0 EXECUTED=4"*) pass "i-hook/run/counts-are-the-parents-own" ;;
        *) fail "i-hook/run/counts-are-the-parents-own" \
               "want the parent's own PASS=4 FAIL=0 SKIP=0 EXECUTED=4 contract" ;;
    esac
    # Neutralisation must PRESERVE the child's text, only defuse its shape.
    case "$out" in
        *"[run-all:neutralized] "*) pass "i-hook/run/child-lines-are-neutralized-not-dropped" ;;
        *) fail "i-hook/run/child-lines-are-neutralized-not-dropped" \
               "no '[run-all:neutralized] ' prefix in the replayed child output" ;;
    esac

    seed_step "$sid" write_tests complete
    drive_hook "$RUNALL_CMD" "$RC_MAIN" "$sid" "$OUT_MAIN" >/dev/null
    status="$(run_tests_status "$sid")"
    assert_eq "i-hook/hook/run-tests-complete" "complete" "$status"
}

# ===========================================================================
# 2. Counter-proof (a) — anything after the contract line breaks attribution
# ===========================================================================
case_trailing_garbage() {
    local sid="1832iiii-0000-4000-8000-000000000002" f status msg
    f="$TMPD/trailing-stdout.txt"
    cp "$OUT_MAIN" "$f"
    printf 'stray trailing segment\n' >> "$f"
    seed_step "$sid" write_tests complete
    seed_step "$sid" run_tests complete
    msg="$(drive_hook "$RUNALL_CMD" 0 "$sid" "$f")"
    status="$(run_tests_status "$sid")"
    assert_eq "i-hook/trailing/demoted-to-pending" "pending" "$status"
    case "$msg" in
        *stdout-unattributed*) pass "i-hook/trailing/reason-is-stdout-unattributed" ;;
        *) fail "i-hook/trailing/reason-is-stdout-unattributed" \
               "hook systemMessage did not name stdout-unattributed" ;;
    esac
}

# ===========================================================================
# 3. Counter-proof (b) — with neutralisation disabled the run must NOT complete.
#    The doctored runner is a `cp` inside the fixture that has its neutralisation
#    call rewritten to `cat`; the real tests/run-all.sh is never edited.
# ===========================================================================
case_neutralization_disabled() {
    local sid="1832iiii-0000-4000-8000-000000000003" doctored f rc status msg out
    doctored="$TMPD/doctored/run-all-noneut.sh"
    mkdir -p "$TMPD/doctored"
    cp "$RUNNER" "$doctored"
    sed -i 's/neutralize_stream/cat/g' "$doctored" 2>/dev/null \
        || sed 's/neutralize_stream/cat/g' "$RUNNER" > "$doctored"
    f="$TMPD/noneut-stdout.txt"
    rc=0
    run_with_timeout 120 env "TESTS_DIR=$FX" "RUN_ALL_CACHE_DIR=$RUN_ALL_CACHE_DIR" \
        "RUN_ALL_PARALLELISM_LIB=$AGENTS_DIR/bin/lib/run-all-parallelism.sh" \
        bash "$doctored" -j 4 "$FX/t1.sh" "$FX/t2.sh" "$FX/t3.sh" "$FX/t4.sh" \
        > "$f" 2>"$TMPD/noneut-stderr.txt" || rc=$?
    out="$(cat "$f")"
    if [ "$(contract_count "$out")" -ge 2 ]; then pass "i-hook/noneut/child-contract-reaches-stdout"
    else fail "i-hook/noneut/child-contract-reaches-stdout" \
        "the doctored runner should have leaked a child contract line; count=$(contract_count "$out")"; fi

    seed_step "$sid" write_tests complete
    seed_step "$sid" run_tests complete
    msg="$(drive_hook "$RUNALL_CMD" "$rc" "$sid" "$f")"
    status="$(run_tests_status "$sid")"
    assert_eq "i-hook/noneut/demoted-to-pending" "pending" "$status"
    case "$msg" in
        *stdout-unattributed*) pass "i-hook/noneut/reason-is-stdout-unattributed" ;;
        *) fail "i-hook/noneut/reason-is-stdout-unattributed" \
               "hook systemMessage did not name stdout-unattributed" ;;
    esac
    # The counter-proof doctors a copy inside the fixture; the real runner must be
    # byte-identical to what it was when this file started.
    assert_eq "i-hook/noneut/real-runner-untouched" "$RUNNER_FINGERPRINT" "$(runner_fingerprint)"
}

case_complete
case_trailing_garbage
case_neutralization_disabled

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
