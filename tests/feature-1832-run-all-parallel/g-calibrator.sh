#!/usr/bin/env bash
# tests/feature-1832-run-all-parallel/g-calibrator.sh
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, calibrator, TL2, scope:issue-specific
# Serial: timing-sensitive parallelism measurements must not compete with other tests

# WHY (CPR-WPH): the calibrator is the only writer of the parallelism cache and it
# runs the real suite many times to get there. Two properties therefore matter more
# than the measurement itself. (1) It must never be reachable from a normal run —
# no code path in tests/run-all.sh executes it, and its own name must not read as a
# test command to the run_tests classifier, or a calibration would silently mark the
# workflow step. (2) Its inquiry sub-modes (--help / --dry-run / --print) must cost
# nothing, and a real measurement must be opt-in via RUN_CALIBRATION=1.

# The write side is fenced just as hard: exactly the seven keys the reader accepts,
# a schema equal to the library's SSOT constant, values inside the reader's char
# classes, and — because the calibrator drives run-all repeatedly — ZERO
# contract-shaped lines anywhere in its own output. An unstable measurement must
# write nothing at all rather than persist a bad number.

# RED-FIRST: bin/calibrate-test-parallelism.sh does not exist yet. Every row that
# needs it reports `implementation missing: <path>`; that is the intended failure.

# ISOLATION: RUN_ALL_CACHE_DIR and TESTS_DIR are pinned to temp fixtures, so the
# developer's real ~/.claude/run-all and the real suite are never touched.

# TL3 gap (what this TL2 test does NOT catch): whether the knee-detection heuristic
# picks a genuinely good `jobs` value on real hardware — only S2-9's manual full
# runs can say that. Closest-to-action mitigation: bin/check-verification-gate.sh at
# WORKFLOW_USER_VERIFIED preflight (category: skill-orchestration).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$AGENTS_DIR/tests/run-all.sh"
CAL_REL="bin/calibrate-test-parallelism.sh"
CAL="$AGENTS_DIR/$CAL_REL"
LIB_REL="bin/lib/run-all-parallelism.sh"
LIB="$AGENTS_DIR/$LIB_REL"
EXEC_MODEL="$AGENTS_DIR/hooks/workflow-run-tests/exec-model.js"

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
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

cal_missing() {
    if [ -f "$CAL" ]; then return 1; fi
    fail "$1" "implementation missing: $CAL_REL"
    return 0
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ra-cal-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# --- fixture isolation (rules/test/fixture-isolation.md) --------------------
export CLAUDE_WORKFLOW_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/workflow-plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
export RUN_ALL_CACHE_DIR="$TMPD/cache"
mkdir -p "$RUN_ALL_CACHE_DIR"
CACHE_FILE="$RUN_ALL_CACHE_DIR/parallelism.conf"

# Snapshot the developer's real cache dir BEFORE anything runs, so the closing
# case can prove this file neither created nor removed it.
REAL_RUN_ALL="${HOME:-/nonexistent}/.claude/run-all"
REAL_PRE=0; [ -e "$REAL_RUN_ALL" ] && REAL_PRE=1

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# Stable fixture: four dummies of equal, non-trivial duration, so repeat-to-repeat
# wall time varies by far less than the 1.5x stability threshold.
FXS="$TMPD/fx-stable"; mkdir -p "$FXS"
for i in 1 2 3 4; do
    printf '#!/usr/bin/env bash\n# stable dummy\nsleep 0.5\nexit 0\n' > "$FXS/s$i.sh"
done

# Unstable fixture: the first four invocations are instant, every later one sleeps.
# Repeat 3 is therefore many times slower than repeat 1 — the stability gate must
# refuse to write a cache from that.
FXU="$TMPD/fx-unstable"; mkdir -p "$FXU"
UCOUNTER="$TMPD/ucount"; : > "$UCOUNTER"
for i in 1 2 3 4; do
    cat > "$FXU/u$i.sh" <<UDUMMY
#!/usr/bin/env bash
n=\$(cat "$UCOUNTER" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" > "$UCOUNTER"
if [ "\$n" -gt 4 ]; then sleep 1; fi
exit 0
UDUMMY
done

# --- drivers ----------------------------------------------------------------
C_OUT=""; C_ERR=""; C_RC=0
# run_cal <env-assignments-as-args...> -- <cal-args...>
run_cal() {
    local tests_dir="$1"; shift
    local extra_env="$1"; shift
    C_RC=0
    : > "$TMPD/cal-stderr.txt"
    if [ -n "$extra_env" ]; then
        C_OUT="$(run_with_timeout 120 env "RUN_ALL_CACHE_DIR=$RUN_ALL_CACHE_DIR" \
            "TESTS_DIR=$tests_dir" "$extra_env" bash "$CAL" "$@" 2>"$TMPD/cal-stderr.txt")" || C_RC=$?
    else
        C_OUT="$(run_with_timeout 120 env "RUN_ALL_CACHE_DIR=$RUN_ALL_CACHE_DIR" \
            "TESTS_DIR=$tests_dir" bash "$CAL" "$@" 2>"$TMPD/cal-stderr.txt")" || C_RC=$?
    fi
    C_ERR="$(cat "$TMPD/cal-stderr.txt")"
}

CAL_ENV=()
run_cal2() {
    C_RC=0
    : > "$TMPD/cal-stderr.txt"
    C_OUT="$(run_with_timeout 120 env ${CAL_ENV[@]+"${CAL_ENV[@]}"} bash "$CAL" "$@" \
        2>"$TMPD/cal-stderr.txt")" || C_RC=$?
    C_ERR="$(cat "$TMPD/cal-stderr.txt")"
}

contract_count() {
    printf '%s\n' "$1" | grep -cE '^[[:space:]]*RUN_CONTRACT: PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+ EXECUTED=[0-9]+' || true
}
cache_value() { sed -n "s/^$1=//p" "$CACHE_FILE" 2>/dev/null | head -1; }
cache_keys() { sed -n 's/^\([a-z_]*\)=.*/\1/p' "$CACHE_FILE" 2>/dev/null | LC_ALL=C sort | tr '\n' ' '; }

# ===========================================================================
# 1. Unreachable from a normal run (invariant 4)
# ===========================================================================
case_unreachable() {
    local hits got
    hits="$(grep -cE '(bash|sh|exec|source|^[[:space:]]*\.)[[:space:]]+[^[:space:]]*calibrate-test-parallelism\.sh' \
        "$RUNNER" 2>/dev/null || true)"
    assert_eq "g-cal/unreachable/runner-never-executes-it" "0" "$hits"

    if [ ! -f "$EXEC_MODEL" ]; then
        fail "g-cal/unreachable/name-is-not-a-test-command" "missing: hooks/workflow-run-tests/exec-model.js"
        return
    fi
    got="$(run_with_timeout 30 node -e '
try {
  const m = require(process.argv[1]);
  process.stdout.write(String(m.isTestCommand("bash bin/calibrate-test-parallelism.sh --dry-run")));
} catch (e) { process.stdout.write("ERR"); }
' "$(nodepath "$EXEC_MODEL")" 2>/dev/null)"
    assert_eq "g-cal/unreachable/name-is-not-a-test-command" "false" "$got"
}

# ===========================================================================
# 2. Inquiry sub-modes cost nothing and write nothing
# ===========================================================================
case_inquiry() {
    local mode
    for mode in --help --dry-run; do
        local n="${mode#--}"
        if cal_missing "g-cal/inquiry/$n-exit-zero"; then
            fail "g-cal/inquiry/$n-writes-no-cache" "implementation missing: $CAL_REL"
            fail "g-cal/inquiry/$n-no-contract-shape" "implementation missing: $CAL_REL"
            continue
        fi
        rm -f "$CACHE_FILE"
        run_cal "$FXS" "" "$mode"
        assert_eq "g-cal/inquiry/$n-exit-zero" "0" "$C_RC"
        if [ -e "$CACHE_FILE" ]; then
            fail "g-cal/inquiry/$n-writes-no-cache" "$mode wrote $CACHE_FILE"
        else pass "g-cal/inquiry/$n-writes-no-cache"; fi
        assert_eq "g-cal/inquiry/$n-no-contract-shape" "0" "$(contract_count "$C_OUT$C_ERR")"
    done

    # --print reports the cached decision without measuring or rewriting.
    if cal_missing "g-cal/inquiry/print-without-cache-is-nonzero"; then
        fail "g-cal/inquiry/print-with-cache-shows-jobs" "implementation missing: $CAL_REL"
        fail "g-cal/inquiry/print-leaves-cache-byte-identical" "implementation missing: $CAL_REL"
        return
    fi
    rm -f "$CACHE_FILE"
    run_cal "$FXS" "" --print
    if [ "$C_RC" -ne 0 ]; then pass "g-cal/inquiry/print-without-cache-is-nonzero"
    else fail "g-cal/inquiry/print-without-cache-is-nonzero" "want non-zero, got 0"; fi
}

# ===========================================================================
# 3. A real measurement is opt-in
# ===========================================================================
case_opt_in() {
    if cal_missing "g-cal/optin/without-flag-exits-77"; then
        fail "g-cal/optin/without-flag-writes-no-cache" "implementation missing: $CAL_REL"
        return
    fi
    rm -f "$CACHE_FILE"
    run_cal "$FXS" "" --sample 2 --jobs-list "1 2" --repeat 3 --warmup 0
    assert_eq "g-cal/optin/without-flag-exits-77" "77" "$C_RC"
    if [ -e "$CACHE_FILE" ]; then
        fail "g-cal/optin/without-flag-writes-no-cache" "a cache was written without RUN_CALIBRATION=1"
    else pass "g-cal/optin/without-flag-writes-no-cache"; fi
}

# ===========================================================================
# 4. A stable measurement writes exactly the reader's seven keys
# ===========================================================================
EXPECTED_KEYS="count_bucket host_id jobs measured_at repeat sample_size schema "
case_write() {
    local names n schema_want v before after
    names="exit-zero cache-in-pinned-dir exactly-seven-keys schema-matches-ssot \
           jobs-in-range measured-at-charset host-id-charset bucket-numeric \
           no-contract-shape print-agrees"
    if cal_missing "g-cal/write/exit-zero"; then
        for n in $names; do
            [ "$n" = "exit-zero" ] && continue
            fail "g-cal/write/$n" "implementation missing: $CAL_REL"
        done
        return
    fi
    rm -f "$CACHE_FILE"
    run_cal "$FXS" "RUN_CALIBRATION=1" --sample 2 --jobs-list "1 2" --repeat 3 --warmup 0
    assert_eq "g-cal/write/exit-zero" "0" "$C_RC"
    if [ ! -e "$CACHE_FILE" ]; then
        for n in cache-in-pinned-dir exactly-seven-keys schema-matches-ssot jobs-in-range \
                 measured-at-charset host-id-charset bucket-numeric print-agrees; do
            fail "g-cal/write/$n" "no cache at the pinned RUN_ALL_CACHE_DIR"
        done
        assert_eq "g-cal/write/no-contract-shape" "0" "$(contract_count "$C_OUT$C_ERR")"
        return
    fi
    pass "g-cal/write/cache-in-pinned-dir"
    assert_eq "g-cal/write/exactly-seven-keys" "$EXPECTED_KEYS" "$(cache_keys)"

    schema_want="1"
    if [ -f "$LIB" ]; then
        schema_want="$(run_with_timeout 30 bash -c '. "$0" >/dev/null 2>&1; printf "%s" "${RUN_ALL_CACHE_SCHEMA:-1}"' "$LIB" 2>/dev/null)"
    fi
    assert_eq "g-cal/write/schema-matches-ssot" "$schema_want" "$(cache_value schema)"

    v="$(cache_value jobs)"
    case "$v" in
        ''|*[!0-9]*) fail "g-cal/write/jobs-in-range" "jobs=$(printf '%q' "$v") is not numeric" ;;
        *) if [ "$v" -ge 1 ] && [ "$v" -le 1024 ]; then pass "g-cal/write/jobs-in-range"
           else fail "g-cal/write/jobs-in-range" "jobs=$v outside 1..1024"; fi ;;
    esac
    v="$(cache_value measured_at)"
    if [ -n "$v" ] && [ "${#v}" -le 24 ] && case "$v" in *[!0-9TZ:+-]*) false ;; *) true ;; esac; then
        pass "g-cal/write/measured-at-charset"
    else fail "g-cal/write/measured-at-charset" "measured_at=$(printf '%q' "$v") fails the reader's char class"; fi
    v="$(cache_value host_id)"
    if [ -n "$v" ] && [ "${#v}" -le 200 ] && case "$v" in *[!A-Za-z0-9._\|-]*) false ;; *) true ;; esac; then
        pass "g-cal/write/host-id-charset"
    else fail "g-cal/write/host-id-charset" "host_id fails the reader's char class"; fi
    v="$(cache_value count_bucket)"
    case "$v" in
        ''|*[!0-9]*) fail "g-cal/write/bucket-numeric" "count_bucket=$(printf '%q' "$v")" ;;
        *) pass "g-cal/write/bucket-numeric" ;;
    esac
    assert_eq "g-cal/write/no-contract-shape" "0" "$(contract_count "$C_OUT$C_ERR")"

    before="$(cat "$CACHE_FILE")"
    run_cal "$FXS" "" --print
    after="$(cat "$CACHE_FILE")"
    case "$C_OUT" in
        *"$(cache_value jobs)"*) pass "g-cal/inquiry/print-with-cache-shows-jobs" ;;
        *) fail "g-cal/inquiry/print-with-cache-shows-jobs" "--print did not report the cached jobs value" ;;
    esac
    assert_eq "g-cal/inquiry/print-leaves-cache-byte-identical" "$before" "$after"
    assert_eq "g-cal/write/print-agrees" "0" "$C_RC"
}

# ===========================================================================
# 5. An unstable measurement writes nothing
# ===========================================================================
case_stability_gate() {
    if cal_missing "g-cal/stability/unstable-exits-1"; then
        fail "g-cal/stability/unstable-writes-no-cache" "implementation missing: $CAL_REL"
        fail "g-cal/stability/unstable-explains-itself" "implementation missing: $CAL_REL"
        return
    fi
    rm -f "$CACHE_FILE"
    : > "$UCOUNTER"
    run_cal "$FXU" "RUN_CALIBRATION=1" --sample 2 --jobs-list "1" --repeat 3 --warmup 0
    assert_eq "g-cal/stability/unstable-exits-1" "1" "$C_RC"
    if [ -e "$CACHE_FILE" ]; then
        fail "g-cal/stability/unstable-writes-no-cache" "an unstable measurement was persisted"
    else pass "g-cal/stability/unstable-writes-no-cache"; fi
    case "$C_ERR" in
        *unstable*|*stability*|*variance*) pass "g-cal/stability/unstable-explains-itself" ;;
        *) fail "g-cal/stability/unstable-explains-itself" "stderr must state why no cache was written" ;;
    esac
}

# ===========================================================================
# 6. Synthetic measurement curves — the knee is SELECTED, not guessed
# ===========================================================================

# WHY: a range check (1..1024) cannot tell an empirical calibrator apart from
# `echo jobs=1`. The user rejected core-count heuristics precisely so that this
# selection is measured, so the selection rule itself has to be pinned.

# SEAM (must be implemented by bin/calibrate-test-parallelism.sh):
# RUN_ALL_CALIBRATION_MEASURE_CMD replaces the real timed suite run. When set and
# non-empty (and RUN_CALIBRATION=1), the calibrator runs
# `bash "$RUN_ALL_CALIBRATION_MEASURE_CMD" <jobs>` once per measurement — warmups
# included — and reads ONE non-negative integer, the elapsed milliseconds, from
# its stdout. A non-zero exit is a failed sample. Nothing else about the approved
# design changes: same cache format, same keys, same gates.

# Throughput is therefore 1/elapsed, and the rule under assertion is:
# knee = the smallest width w with 100 * min_median_elapsed >= 95 * median_elapsed(w).

# make_stub <spec>; spec is "<width>:<ms>,<ms>,<ms> ..." — the Nth invocation of a
# width returns the Nth value (last value repeats). Order-independent by design,
# so a row's expectation holds whatever traversal order the calibrator picks.

# The directory MUST come from mktemp, not a shell counter: these helpers are
# called inside `$(...)`, so a counter increment would be lost with the subshell
# and every row would inherit the previous row's occurrence state.
make_stub() {
    local d
    d="$(mktemp -d "$TMPD/stub.XXXXXX")"
    mkdir -p "$d/state"
    printf '%s\n' "$1" > "$d/spec"
    : > "$d/calls.log"
    cat > "$d/measure.sh" <<'STUB'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd)"
w="${1:-}"
printf '%s\n' "$w" >> "$d/calls.log"
n="$(cat "$d/state/$w" 2>/dev/null || echo 0)"; n=$((n + 1))
printf '%s\n' "$n" > "$d/state/$w"
vals=""
for grp in $(cat "$d/spec"); do
    case "$grp" in "$w":*) vals="${grp#*:}" ;; esac
done
[ -n "$vals" ] || { echo "no spec for width $w" >&2; exit 3; }
IFS=',' read -r -a arr <<< "$vals"
i=$((n - 1)); [ "$i" -ge "${#arr[@]}" ] && i=$(( ${#arr[@]} - 1 ))
printf '%s\n' "${arr[$i]}"
STUB
    chmod +x "$d/measure.sh" 2>/dev/null || true
    printf '%s' "$d"
}

# make_drift_stub <base-ms> <step-ms>: elapsed depends on the GLOBAL call index,
# not the width — a pure warm-up drift with zero real width effect.
make_drift_stub() {
    local d
    d="$(mktemp -d "$TMPD/stub.XXXXXX")"
    : > "$d/calls.log"; printf '0\n' > "$d/n"
    cat > "$d/measure.sh" <<STUB
#!/usr/bin/env bash
d="\$(cd "\$(dirname "\$0")" && pwd)"
printf '%s\n' "\${1:-}" >> "\$d/calls.log"
n="\$(cat "\$d/n" 2>/dev/null || echo 0)"
printf '%s\n' "\$((n + 1))" > "\$d/n"
printf '%s\n' "\$(( $1 + $2 * n ))"
STUB
    chmod +x "$d/measure.sh" 2>/dev/null || true
    printf '%s' "$d"
}

synth_env() {
    CAL_ENV=("RUN_ALL_CACHE_DIR=$RUN_ALL_CACHE_DIR" "TESTS_DIR=$FXS" "RUN_CALIBRATION=1"
             "RUN_ALL_CALIBRATION_MEASURE_CMD=$1/measure.sh")
}

case_knee_curves() {
    local have=1; [ -f "$CAL" ] || have=0
    local name spec want_rc want_jobs d
    while IFS='|' read -r name spec want_rc want_jobs; do
        name="$(trim "$name")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        spec="$(trim "$spec")"; want_rc="$(trim "$want_rc")"; want_jobs="$(trim "$want_jobs")"
        if [ "$have" -eq 0 ]; then
            fail "g-cal/knee/$name/exit-code" "implementation missing: $CAL_REL"
            fail "g-cal/knee/$name/selected-jobs" "implementation missing: $CAL_REL"
            continue
        fi
        rm -f "$CACHE_FILE"
        d="$(make_stub "$spec")"
        synth_env "$d"
        run_cal2 --sample 4 --jobs-list "1 2 4 8" --repeat 3 --warmup 0
        assert_eq "g-cal/knee/$name/exit-code" "$want_rc" "$C_RC"
        if [ "$want_jobs" = "none" ]; then
            if [ -e "$CACHE_FILE" ]; then
                fail "g-cal/knee/$name/selected-jobs" "stability gate did not fire: jobs=$(cache_value jobs)"
            else pass "g-cal/knee/$name/selected-jobs"; fi
        else
            assert_eq "g-cal/knee/$name/selected-jobs" "$want_jobs" "$(cache_value jobs)"
        fi
    done <<'TABLE'
# name                 | width:ms,ms,ms per repeat (jobs-list 1 2 4 8, repeat 3)                | rc | jobs
clean-knee             | 1:8000,8000,8000 2:4000,4000,4000 4:2000,2000,2000 8:1950,1950,1950   | 0  | 4
saturation             | 1:1000,1000,1000 2:1000,1000,1000 4:1000,1000,1000 8:1000,1000,1000   | 0  | 1
tie-smaller-width-wins | 1:2000,2000,2000 2:1000,1000,1000 4:990,990,990 8:5000,5000,5000      | 0  | 2
exactly-95-percent     | 1:2000,2000,2000 2:1000,1000,1000 4:950,950,950 8:950,950,950         | 0  | 2
peak-then-decline      | 1:4000,4000,4000 2:1000,1000,1000 4:2000,2000,2000 8:8000,8000,8000   | 0  | 2
noisy-under-gate       | 1:1000,1400,1200 2:500,600,550 4:480,500,490 8:470,500,480            | 0  | 4
noisy-over-gate        | 1:1000,1600,1000 2:500,500,500 4:480,480,480 8:470,470,470            | 1  | none
TABLE
}

# ===========================================================================
# 7. Warmup discard and order-crossing traversal
# ===========================================================================
case_protocol() {
    local d calls w1 w2 w3
    if [ ! -f "$CAL" ]; then
        for n in warmup-exit-zero warmup-excluded-from-selection measurement-call-count \
                 order-crossing-traversal-varies order-crossing-neutralizes-drift; do
            fail "g-cal/protocol/$n" "implementation missing: $CAL_REL"
        done
        return
    fi

    # A 5000ms warmup against 1000/500ms repeats: counted, it would trip the 1.5x
    # stability gate; discarded, selection proceeds and picks width 2.
    rm -f "$CACHE_FILE"
    d="$(make_stub "1:5000,1000,1000,1000 2:5000,500,500,500")"
    synth_env "$d"
    run_cal2 --sample 4 --jobs-list "1 2" --repeat 3 --warmup 1
    assert_eq "g-cal/protocol/warmup-exit-zero" "0" "$C_RC"
    assert_eq "g-cal/protocol/warmup-excluded-from-selection" "2" "$(cache_value jobs)"
    calls="$(grep -c . "$d/calls.log" 2>/dev/null || echo 0)"
    assert_eq "g-cal/protocol/measurement-call-count" "8" "$calls"

    # Pure monotonic drift, no real width effect. A single-order traversal would
    # read it as "width 1 is fastest" and select jobs=1; the approved protocol
    # crosses the traversal order between repeats, so the median lands on 2.
    rm -f "$CACHE_FILE"
    d="$(make_drift_stub 1000 20)"
    synth_env "$d"
    run_cal2 --sample 4 --jobs-list "1 2 4 8" --repeat 3 --warmup 0
    w1="$(sed -n '1,4p' "$d/calls.log" | tr '\n' ' ')"
    w2="$(sed -n '5,8p' "$d/calls.log" | tr '\n' ' ')"
    w3="$(sed -n '9,12p' "$d/calls.log" | tr '\n' ' ')"
    if [ -n "$w1" ] && { [ "$w1" != "$w2" ] || [ "$w2" != "$w3" ]; }; then
        pass "g-cal/protocol/order-crossing-traversal-varies"
    else
        fail "g-cal/protocol/order-crossing-traversal-varies" \
             "every repeat traversed the same order: $(printf '%q' "$w1")"
    fi
    assert_eq "g-cal/protocol/order-crossing-neutralizes-drift" "2" "$(cache_value jobs)"
}

# ===========================================================================
# 8. The developer's real cache dir was never touched
# ===========================================================================
case_real_home_untouched() {
    local now=0; [ -e "$REAL_RUN_ALL" ] && now=1
    assert_eq "g-cal/isolation/real-home-run-all-untouched" "$REAL_PRE" "$now"
}

case_unreachable
case_inquiry
case_opt_in
case_write
case_stability_gate
case_knee_curves
case_protocol
case_real_home_untouched

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
