#!/usr/bin/env bash
# d-jobs-surface.sh — the -j / --jobs / RUN_ALL_JOBS / --deadline parser surface.
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, scope:issue-specific

# WHY (CPR-WPH): `-j 1` is the documented escape hatch back to the old
# sequential behaviour, so every spelling of the surface must mean the same
# thing, CLI must beat env, and a typo must be refused loudly (exit 2, no
# contract line) rather than silently running at some other width. A rejected
# invocation that still printed a contract would let a run that never happened
# claim a verdict — which is how a suite goes green without executing.

# This is a parser, so the cases are a named table
# (skills/_shared/test-design/parser-regex-tests.md): one row per spelling,
# covering CLI and environment forms, unknown options, empty values, and both
# sides of the numeric limits.

# RED-FIRST: no option parsing exists yet — line 43 of tests/run-all.sh honours
# `--all` only as $1, so `-j 4 --all` globs nothing and reports EXECUTED=0 with
# exit 0. Every accepted row is therefore red on EXECUTED, and every refused row
# is red on the exit code. Both are intentional.

# NOTE for the implementer: no upper bound is specified for --deadline, so only
# its lower/ill-formed side is pinned as refused; 86400 is pinned as accepted.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "d-jobs-surface"

# --- fixture: instant, one of each verdict --------------------------------
ROOT="$(fx_new_root)"
TESTS="$(fx_tests_dir "$ROOT")"
fx_add_dummy "$ROOT" g1 --lines 1
fx_add_dummy "$ROOT" g2 --exit 77
fx_add_dummy "$ROOT" g3 --exit 3

# The fixture's own verdict, shared by every accepted row.
OK_EXEC=3
OK_RC=1

trim() { printf '%s' "$1" | sed 's/^[[:blank:]]*//; s/[[:blank:]]*$//'; }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then fx_pass "$name -> $got"
    else fx_fail "$name -> want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

# run_row <name> <envspec> <args> <verdict> — one runner invocation.
# verdict is `ok` (parsed: exit 1, exactly one contract, EXECUTED=3) or
# `refused` (exit 2 and NO contract line, so nothing can claim a result).
run_row() {
    local name="$1" envspec="$2" args="$3" verdict="$4"
    local out="$FX_TMP_ROOT/row-$name.out" err="$FX_TMP_ROOT/row-$name.err"
    local rc=0 n got
    eval "$envspec fx_exec \"\$ROOT\" 30 \"\$out\" \"\$err\" $args" || rc=$?
    n="$(fx_count_contract "$out")"
    if [ "$verdict" = "refused" ]; then
        got="exit=$rc contract=$n"
        assert_eq "D1/$name" "exit=2 contract=0" "$got"
    else
        got="exit=$rc contract=$n EXECUTED=$(fx_contract_field "$out" EXECUTED)"
        assert_eq "D1/$name" "exit=$OK_RC contract=1 EXECUTED=$OK_EXEC" "$got"
    fi
}

while IFS='|' read -r name envspec args verdict; do
    case "$name" in ''|\#*) continue ;; esac
    run_row "$(trim "$name")" "$(trim "$envspec")" "$(trim "$args")" "$(trim "$verdict")"
done <<'TABLE'
# --- jobs: accepted spellings, CLI then environment ---
cli-j-space         |                    | -j 4 --all                | ok
cli-jobs-space      |                    | --jobs 4 --all            | ok
cli-jobs-equals     |                    | --jobs=4 --all            | ok
cli-j-one           |                    | -j 1 --all                | ok
cli-j-auto          |                    | -j auto --all             | ok
env-jobs-4          | RUN_ALL_JOBS=4     | --all                     | ok
env-jobs-1          | RUN_ALL_JOBS=1     | --all                     | ok
env-jobs-auto       | RUN_ALL_JOBS=auto  | --all                     | ok
# --- deadline: accepted spellings, CLI then environment ---
cli-deadline-space  |                    | --deadline 86400 -j 4 --all  | ok
cli-deadline-equals |                    | --deadline=86400 -j 4 --all  | ok
env-deadline        | RUN_ALL_DEADLINE=86400 | -j 4 --all            | ok
# --- numeric limits, both sides ---
jobs-1024-accepted  |                    | -j 1024 --all             | ok
jobs-1025-refused   |                    | -j 1025 --all             | refused
env-jobs-1024-ok    | RUN_ALL_JOBS=1024  | --all                     | ok
env-jobs-1025-bad   | RUN_ALL_JOBS=1025  | --all                     | refused
# --- ill-formed jobs values ---
jobs-zero           |                    | -j 0 --all                | refused
jobs-negative       |                    | -j -3 --all               | refused
jobs-word           |                    | -j abc --all              | refused
jobs-auto2          |                    | -j auto2 --all            | refused
jobs-float          |                    | -j 2.5 --all              | refused
jobs-no-value       |                    | -j                        | refused
jobs-empty          |                    | -j '' --all               | refused
jobs-equals-empty   |                    | --jobs= --all             | refused
env-jobs-empty      | RUN_ALL_JOBS=      | --all                     | refused
env-jobs-zero       | RUN_ALL_JOBS=0     | --all                     | refused
env-jobs-word       | RUN_ALL_JOBS=abc   | --all                     | refused
env-jobs-negative   | RUN_ALL_JOBS=-2    | --all                     | refused
# --- ill-formed deadline values ---
deadline-zero       |                    | --deadline 0 --all        | refused
deadline-word       |                    | --deadline abc --all      | refused
deadline-negative   |                    | --deadline -5 --all       | refused
deadline-empty      |                    | --deadline '' --all       | refused
deadline-eq-empty   |                    | --deadline= --all         | refused
deadline-no-value   |                    | --deadline                | refused
env-deadline-word   | RUN_ALL_DEADLINE=abc | --all                   | refused
env-deadline-neg    | RUN_ALL_DEADLINE=-5  | --all                   | refused
env-deadline-empty  | RUN_ALL_DEADLINE=    | --all                   | refused
# --- unknown options ---
unknown-long        |                    | --nope --all              | refused
unknown-short       |                    | -z --all                  | refused
unknown-jobsish     |                    | --jobs-extra 4 --all      | refused
unknown-equals      |                    | --nope=1 --all            | refused
TABLE

# --- D2: CLI beats env, observed through wall time ------------------------
SLOW="$(fx_new_root)"
fx_add_dummy "$SLOW" s1 --sleep 2
fx_add_dummy "$SLOW" s2 --sleep 2
fx_add_dummy "$SLOW" s3 --sleep 2
fx_add_dummy "$SLOW" s4 --sleep 2
T0="$(fx_now_ms)"
RUN_ALL_JOBS=1 fx_exec "$SLOW" 60 "$FX_TMP_ROOT/prec.out" "$FX_TMP_ROOT/prec.err" -j 4 --all
T1="$(fx_now_ms)"
PREC_MS=$((T1 - T0))
PREC_EXEC="$(fx_contract_field "$FX_TMP_ROOT/prec.out" EXECUTED)"
if [ "$PREC_EXEC" = "4" ] && [ "$PREC_MS" -lt 6000 ]; then
    fx_pass "D2. CLI -j 4 overrides RUN_ALL_JOBS=1: four 2s tests finished in ${PREC_MS}ms"
else
    fx_fail "D2. want EXECUTED=4 within 6000ms (CLI beats env), got EXECUTED=$PREC_EXEC in ${PREC_MS}ms"
fi

# --- D3: the accepted spellings are not merely accepted, they agree -------
IDENT=1
for tag in cli-jobs-space cli-jobs-equals env-jobs-4; do
    cmp -s "$FX_TMP_ROOT/row-cli-j-space.out" "$FX_TMP_ROOT/row-$tag.out" || IDENT=0
done
BASE_EXEC="$(fx_contract_field "$FX_TMP_ROOT/row-cli-j-space.out" EXECUTED)"
if [ "$BASE_EXEC" = "$OK_EXEC" ] && [ "$IDENT" -eq 1 ]; then
    fx_pass "D3. -j 4 / --jobs 4 / --jobs=4 / RUN_ALL_JOBS=4 run the same $OK_EXEC tests with identical stdout"
else
    fx_fail "D3. want EXECUTED=$OK_EXEC and byte-identical stdout across the four width-4 spellings, got EXECUTED=$BASE_EXEC identical=$IDENT"
fi

# --- D4: -j 1 stdout matches a hand-built golden --------------------------
GOLDEN="$FX_TMP_ROOT/golden.out"
{
    printf 'g1 line 1\n'
    printf 'PASS: %s/g1.sh\n' "$TESTS"
    printf 'SKIP: %s/g2.sh\n' "$TESTS"
    printf 'FAIL: %s/g3.sh (exit 3)\n' "$TESTS"
    printf '\n'
    printf 'Results: PASS=1  FAIL=1  SKIP=1\n'
    printf 'RUN_CONTRACT: PASS=1 FAIL=1 SKIP=1 EXECUTED=3\n'
} > "$GOLDEN"

fx_exec "$ROOT" 60 "$FX_TMP_ROOT/j1.out" "$FX_TMP_ROOT/j1.err" -j 1 --all
J1_RC=$?
cmp -s "$GOLDEN" "$FX_TMP_ROOT/j1.out"
CMP_RC=$?
if [ "$CMP_RC" -eq 0 ] && [ "$J1_RC" -eq 1 ]; then
    fx_pass "D4. -j 1 stdout is byte-identical to the golden and still exits 1 on FAIL>0"
else
    fx_fail "D4. -j 1 stdout differs from the golden (cmp rc=$CMP_RC, exit $J1_RC)"
    diff "$GOLDEN" "$FX_TMP_ROOT/j1.out" 2>/dev/null | head -n 10 | fx_mask | sed 's/^/    | /'
fi

# --- D5: RUN_ALL_PROGRESS=off silences the parent's stderr ----------------
# NOT asserted as "stderr is empty": `set -m` may emit job-control notices, and
# those are harmless — what matters is that no line reaches a downstream parser.
RUN_ALL_PROGRESS=off fx_exec "$ROOT" 60 "$FX_TMP_ROOT/quiet.out" "$FX_TMP_ROOT/quiet.err" -j 4 --all
Q_EXEC="$(fx_contract_field "$FX_TMP_ROOT/quiet.out" EXECUTED)"
N_PROGRESS="$(grep -c '^\[run-all\] ' "$FX_TMP_ROOT/quiet.err" || true)"
N_SHAPES="$(grep -cE "$FX_CONTRACT_RE"'|^FAIL:[[:blank:]]+.+[[:blank:]]\(exit -?[0-9]+\)[[:blank:]]*$|^Results:[[:blank:]]*.+$' "$FX_TMP_ROOT/quiet.err" || true)"
if [ "$Q_EXEC" = "3" ] && [ "$N_PROGRESS" = "0" ] && [ "$N_SHAPES" = "0" ]; then
    fx_pass "D5. RUN_ALL_PROGRESS=off: 3 tests ran, stderr has no '[run-all] ' line and no parser-shaped line"
else
    fx_fail "D5. want EXECUTED=3 with 0 progress lines and 0 parser-shaped stderr lines, got EXECUTED=$Q_EXEC progress=$N_PROGRESS shapes=$N_SHAPES"
fi

# --- D6: the positive side — progress ON, on stderr, for ORDINARY jobs -----

# D5 only proves the OFF switch silences things; a runner that never emitted a
# progress line for a non-serial job would pass it. The default (no
# RUN_ALL_PROGRESS at all) is what users actually get, so it is measured here:
# visible on stderr, never on stdout, never parser-shaped, and one line per
# job actually run. stdout must stay byte-identical to the silenced run,
# because stdout is the only channel a downstream parser reads.

PROG_OUT="$FX_TMP_ROOT/prog.out"
PROG_ERR="$FX_TMP_ROOT/prog.err"
fx_exec "$ROOT" 60 "$PROG_OUT" "$PROG_ERR" -j 4 --all
P_EXEC="$(fx_contract_field "$PROG_OUT" EXECUTED)"
P_ERR_N="$(grep -c '^\[run-all\] ' "$PROG_ERR" || true)"
P_OUT_N="$(grep -c '^\[run-all\] ' "$PROG_OUT" || true)"
P_SHAPES="$(grep -cE "$FX_CONTRACT_RE"'|^FAIL:[[:blank:]]+.+[[:blank:]]\(exit -?[0-9]+\)[[:blank:]]*$|^Results:[[:blank:]]*.+$' "$PROG_ERR" || true)"

if [ "$P_EXEC" = "3" ] && [ "$P_ERR_N" -ge 1 ] && [ "$P_OUT_N" = "0" ]; then
    fx_pass "D6a. progress on by default: EXECUTED=3 with $P_ERR_N '[run-all] ' line(s) on stderr and 0 on stdout"
else
    fx_fail "D6a. want EXECUTED=3 with at least 1 '[run-all] ' stderr line and 0 on stdout, got EXECUTED=$P_EXEC stderr=$P_ERR_N stdout=$P_OUT_N"
fi

if [ "$P_EXEC" = "3" ] && [ "$P_SHAPES" = "0" ]; then
    fx_pass "D6b. EXECUTED=3 and no progress line is parser-shaped (no contract, no 'FAIL: ... (exit N)', no 'Results:')"
else
    fx_fail "D6b. want EXECUTED=3 with 0 parser-shaped stderr lines under progress, got EXECUTED=$P_EXEC shapes=$P_SHAPES"
fi

P_NAMED=0
for id in g1 g2 g3; do
    grep -q "^\[run-all\] .*$id\.sh" "$PROG_ERR" && P_NAMED=$((P_NAMED + 1))
done
if [ "$P_EXEC" = "3" ] && [ "$P_NAMED" = "3" ]; then
    fx_pass "D6c. all 3 ordinary jobs that ran are named by a '[run-all] ' progress line"
else
    fx_fail "D6c. want each of the 3 executed ordinary jobs named by a progress line, got EXECUTED=$P_EXEC named=$P_NAMED of 3"
fi

cmp -s "$FX_TMP_ROOT/quiet.out" "$PROG_OUT"
P_SAME=$?
if [ "$P_EXEC" = "3" ] && [ "$P_SAME" -eq 0 ]; then
    fx_pass "D6d. EXECUTED=3 and turning progress on leaves stdout byte-identical to RUN_ALL_PROGRESS=off"
else
    fx_fail "D6d. want EXECUTED=3 with stdout identical to the RUN_ALL_PROGRESS=off run, got EXECUTED=$P_EXEC cmp=$P_SAME"
fi

ON_OUT="$FX_TMP_ROOT/progon.out"
ON_ERR="$FX_TMP_ROOT/progon.err"
RUN_ALL_PROGRESS=on fx_exec "$ROOT" 60 "$ON_OUT" "$ON_ERR" -j 4 --all
ON_EXEC="$(fx_contract_field "$ON_OUT" EXECUTED)"
ON_ERR_N="$(grep -c '^\[run-all\] ' "$ON_ERR" || true)"
if [ "$ON_EXEC" = "3" ] && [ "$ON_ERR_N" = "$P_ERR_N" ] && cmp -s "$PROG_OUT" "$ON_OUT"; then
    fx_pass "D6e. EXECUTED=3: explicit RUN_ALL_PROGRESS=on is the default ($ON_ERR_N progress lines, identical stdout)"
else
    fx_fail "D6e. want the explicit 'on' spelling to equal the default, got EXECUTED=$ON_EXEC progress=$ON_ERR_N vs default $P_ERR_N"
fi

fx_finish
