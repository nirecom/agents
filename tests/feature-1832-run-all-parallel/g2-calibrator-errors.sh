#!/usr/bin/env bash
# tests/feature-1832-run-all-parallel/g2-calibrator-errors.sh
# Tests: bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, calibrator, error-matrix, injection, idempotency, TL2, scope:issue-specific
# Serial: drives the calibrator, which the sibling g-calibrator.sh also drives

# WHY (CPR-WPH): the calibrator is the SOLE cache writer, so every rejection row
# asserts 4 invariants: rejects cleanly (not skip/timeout), no RUN_CONTRACT: shape
# leaks, no injection side effect, and the pre-existing cache survives byte-for-byte.

# RED-FIRST: bin/calibrate-test-parallelism.sh doesn't exist yet; every row
# reports `implementation missing: <path>`.

# ISOLATION: RUN_ALL_CACHE_DIR/TESTS_DIR/measurement seam pinned to temp fixtures —
# the real ~/.claude/run-all is never reachable.

# TL3 gap: a real filesystem crash mid-write (power loss, ENOSPC) is not covered here.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CAL_REL="bin/calibrate-test-parallelism.sh"
CAL="$AGENTS_DIR/$CAL_REL"

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
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ra-cal2-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

export CLAUDE_WORKFLOW_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/workflow-plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

CACHE_DIR="$TMPD/cache"; mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/parallelism.conf"
GOLDEN="$TMPD/golden.conf"
SENTINEL="$TMPD/INJECTED"

REAL_RUN_ALL="${HOME:-/nonexistent}/.claude/run-all"
REAL_PRE=0; [ -e "$REAL_RUN_ALL" ] && REAL_PRE=1

# A destination whose parent is a regular file — portable "unwritable" without
# relying on chmod semantics, which differ on Windows filesystems.
BLOCKED="$TMPD/blocked"; printf 'not a directory\n' > "$BLOCKED"

FXS="$TMPD/fx"; mkdir -p "$FXS"
for i in 1 2 3 4; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FXS/s$i.sh"; done
FXEMPTY="$TMPD/fx-empty"; mkdir -p "$FXEMPTY"

# --- measurement seam stubs -------------------------------------------------

# SEAM: RUN_ALL_CALIBRATION_MEASURE_CMD — see the sibling g-calibrator.sh header
# for the full contract. Here it only has to be deterministic and instant, so a
# rejection row can never be confused with a slow real measurement.
GOOD_STUB="$TMPD/measure-ok.sh"
cat > "$GOOD_STUB" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    1) printf '1000\n' ;;
    2) printf '500\n' ;;
    *) printf '400\n' ;;
esac
STUB

FAIL_STUB="$TMPD/measure-fail.sh"
cat > "$FAIL_STUB" <<'STUB'
#!/usr/bin/env bash
echo "sample failed" >&2
exit 3
STUB
chmod +x "$GOOD_STUB" "$FAIL_STUB" 2>/dev/null || true

write_golden() {
    cat > "$CACHE_FILE" <<'CONF'
schema=1
host_id=fixture-host
count_bucket=2
jobs=7
measured_at=2024-01-01T00:00:00Z
sample_size=4
repeat=3
CONF
    cp "$CACHE_FILE" "$GOLDEN"
}

C_OUT=""; C_ERR=""; C_RC=0
contract_count() {
    printf '%s\n' "$1" | grep -cE '^[[:space:]]*RUN_CONTRACT: PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+ EXECUTED=[0-9]+' || true
}
cache_value() { sed -n "s/^$1=//p" "$CACHE_FILE" 2>/dev/null | head -1; }
cache_keys() { sed -n 's/^\([a-z_]*\)=.*/\1/p' "$CACHE_FILE" 2>/dev/null | LC_ALL=C sort | tr '\n' ' '; }
verdict() { case "$1" in 0|77|124) printf 'rc=%s' "$1" ;; *) printf 'reject' ;; esac; }

S_DEF=4; J_DEF="1 2"; R_DEF=3; W_DEF=0

# ===========================================================================
# 1. Rejection matrix — one row, four invariants
# ===========================================================================
case_rejections() {
    local have=1; [ -f "$CAL" ] || have=0
    local name field value skip s j r w suite cachedir measure
    local args env_v inv
    while IFS='|' read -r name field value; do
        name="$(trim "$name")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        field="$(trim "$field")"; value="$(trim "$value")"
        if [ "$have" -eq 0 ]; then
            for inv in exit-is-rejection no-contract-line no-injection-side-effect prior-cache-preserved; do
                fail "g2-cal/reject/$name/$inv" "implementation missing: $CAL_REL"
            done
            continue
        fi
        value="${value//%SENT%/$SENTINEL}"
        value="${value//%NL%/$'\n'}"
        [ "$value" = "<EMPTY>" ] && value=""

        s="$S_DEF"; j="$J_DEF"; r="$R_DEF"; w="$W_DEF"
        suite="$FXS"; cachedir="$CACHE_DIR"; measure="$GOOD_STUB"
        skip=""; [ "$value" = "<NONE>" ] && skip="$field"
        case "$field" in
            sample)    [ -n "$skip" ] || s="$value" ;;
            jobs-list) [ -n "$skip" ] || j="$value" ;;
            repeat)    [ -n "$skip" ] || r="$value" ;;
            warmup)    [ -n "$skip" ] || w="$value" ;;
            suite)     case "$value" in empty) suite="$FXEMPTY" ;; *) suite="$TMPD/no-such-suite" ;; esac ;;
            measure)   measure="$FAIL_STUB" ;;
            cache)     cachedir="$BLOCKED/cache" ;;
        esac
        args=()
        [ "$skip" = "sample" ]    || args+=(--sample "$s")
        [ "$skip" = "jobs-list" ] || args+=(--jobs-list "$j")
        [ "$skip" = "repeat" ]    || args+=(--repeat "$r")
        [ "$skip" = "warmup" ]    || args+=(--warmup "$w")
        [ -n "$skip" ] && args+=("--$skip")

        rm -f "$SENTINEL"
        write_golden
        env_v=("RUN_ALL_CACHE_DIR=$cachedir" "TESTS_DIR=$suite" "RUN_CALIBRATION=1"
               "RUN_ALL_CALIBRATION_MEASURE_CMD=$measure")
        C_RC=0
        : > "$TMPD/err.txt"
        C_OUT="$(run_with_timeout 60 env "${env_v[@]}" bash "$CAL" "${args[@]}" 2>"$TMPD/err.txt")" || C_RC=$?
        C_ERR="$(cat "$TMPD/err.txt")"

        assert_eq "g2-cal/reject/$name/exit-is-rejection" "reject" "$(verdict "$C_RC")"
        assert_eq "g2-cal/reject/$name/no-contract-line" "0" "$(contract_count "$C_OUT$C_ERR")"
        if [ -e "$SENTINEL" ]; then
            fail "g2-cal/reject/$name/no-injection-side-effect" "argument value was evaluated by a shell"
        else pass "g2-cal/reject/$name/no-injection-side-effect"; fi
        if cmp -s "$GOLDEN" "$CACHE_FILE"; then pass "g2-cal/reject/$name/prior-cache-preserved"
        else fail "g2-cal/reject/$name/prior-cache-preserved" "a rejected run mutated the existing cache"; fi
    done <<'TABLE'
# name                      | field     | value
sample-zero                 | sample    | 0
sample-negative             | sample    | -1
sample-nonnumeric           | sample    | abc
sample-float                | sample    | 1.5
sample-missing-value        | sample    | <NONE>
jobs-list-empty             | jobs-list | <EMPTY>
jobs-list-nonnumeric-token  | jobs-list | 1 x 4
jobs-list-zero-width        | jobs-list | 0 2
jobs-list-negative-width    | jobs-list | 1 -2
jobs-list-oversize-width    | jobs-list | 1 4096
jobs-list-missing-value     | jobs-list | <NONE>
repeat-zero                 | repeat    | 0
repeat-nonnumeric           | repeat    | abc
repeat-missing-value        | repeat    | <NONE>
warmup-negative             | warmup    | -1
warmup-nonnumeric           | warmup    | abc
warmup-missing-value        | warmup    | <NONE>
suite-empty                 | suite     | empty
suite-nonexistent           | suite     | missing
samples-fail                | measure   | fail
cache-destination-unwritable| cache     | unwritable
inject-sample-cmdsub        | sample    | $(touch %SENT%)
inject-jobs-backtick        | jobs-list | `touch %SENT%`
inject-repeat-semicolon     | repeat    | 1; touch %SENT%
inject-warmup-andand        | warmup    | 0 && touch %SENT%
inject-jobs-newline         | jobs-list | 1 2%NL%touch %SENT%
TABLE
}

# ===========================================================================
# 2. Recalibration over an existing cache — atomic replace, then idempotent
# ===========================================================================
EXPECTED_KEYS="count_bucket host_id jobs measured_at repeat sample_size schema "
run_ok() {
    C_RC=0
    : > "$TMPD/err.txt"
    C_OUT="$(run_with_timeout 60 env "RUN_ALL_CACHE_DIR=$CACHE_DIR" "TESTS_DIR=$FXS" \
        "RUN_CALIBRATION=1" "RUN_ALL_CALIBRATION_MEASURE_CMD=$GOOD_STUB" \
        bash "$CAL" --sample 4 --jobs-list "1 2" --repeat 3 --warmup 0 2>"$TMPD/err.txt")" || C_RC=$?
    C_ERR="$(cat "$TMPD/err.txt")"
}

case_recalibration() {
    local first entries
    if [ ! -f "$CAL" ]; then
        for n in replace-exit-zero replaced-jobs-is-the-knee replaced-cache-has-seven-keys \
                 no-temp-file-left-behind rerun-exit-zero rerun-selects-the-same-jobs \
                 rerun-keeps-the-same-key-set; do
            fail "g2-cal/recalibrate/$n" "implementation missing: $CAL_REL"
        done
        return
    fi
    write_golden
    run_ok
    assert_eq "g2-cal/recalibrate/replace-exit-zero" "0" "$C_RC"
    # Stub curve: width 1 = 1000ms, width 2 = 500ms. Max throughput is at width 2
    # and width 1 is far below the 95% band, so the knee is 2 — never the stale 7.
    assert_eq "g2-cal/recalibrate/replaced-jobs-is-the-knee" "2" "$(cache_value jobs)"
    assert_eq "g2-cal/recalibrate/replaced-cache-has-seven-keys" "$EXPECTED_KEYS" "$(cache_keys)"
    entries="$(ls -A "$CACHE_DIR" 2>/dev/null | tr '\n' ' ')"
    assert_eq "g2-cal/recalibrate/no-temp-file-left-behind" "parallelism.conf " "$entries"

    first="$(cache_value jobs)"
    run_ok
    assert_eq "g2-cal/recalibrate/rerun-exit-zero" "0" "$C_RC"
    assert_eq "g2-cal/recalibrate/rerun-selects-the-same-jobs" "$first" "$(cache_value jobs)"
    assert_eq "g2-cal/recalibrate/rerun-keeps-the-same-key-set" "$EXPECTED_KEYS" "$(cache_keys)"
}

# ===========================================================================
# 3. The developer's real cache dir was never touched
# ===========================================================================
case_real_home_untouched() {
    local now=0; [ -e "$REAL_RUN_ALL" ] && now=1
    assert_eq "g2-cal/isolation/real-home-run-all-untouched" "$REAL_PRE" "$now"
}

case_rejections
case_recalibration
case_real_home_untouched

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
