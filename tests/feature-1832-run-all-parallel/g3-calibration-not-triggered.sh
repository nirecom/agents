#!/usr/bin/env bash
# tests/feature-1832-run-all-parallel/g3-calibration-not-triggered.sh
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, calibrator, sentinel, no-auto-calibration, TL2, scope:issue-specific
# Serial: timing-sensitive parallelism measurements must not compete with other tests

# WHY (CPR-WPH): sibling g-calibrator.sh only greps for the calibrator's literal
# filename, which passes for any indirect invocation. This file proves
# behaviourally that a normal run never calibrates, across every cache state
# (absent/corrupt/host-stale/bucket-stale), even with RUN_CALIBRATION=1 forced.

# THE SENTINELS (layered, so no single evasion defeats them all): L1 measure-cmd
# seam, L2 BASH_ENV script-path log, L3 PATH shim named like the calibrator,
# L4 cache byte-diff.

# RED-FIRST: the calibrator, lib, and `-j auto` don't exist yet; rows report the
# absent notice or `implementation missing: <path>` — both intentional.

# ISOLATION: cache dir and TESTS_DIR are pinned to temp fixtures; the real
# ~/.claude/run-all is never reachable (closing case re-checks it).

# TL3 gap (what this TL2 test does NOT catch): calibration triggered by a real CI
# wrapper outside tests/run-all.sh. Mitigation: bin/check-verification-gate.sh at
# WORKFLOW_USER_VERIFIED preflight (category: skill-orchestration).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$AGENTS_DIR/tests/run-all.sh"
CAL_REL="bin/calibrate-test-parallelism.sh"
CAL="$AGENTS_DIR/$CAL_REL"
LIB_REL="bin/lib/run-all-parallelism.sh"
LIB="$AGENTS_DIR/$LIB_REL"

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

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ra-nocal-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# --- fixture isolation (rules/test/fixture-isolation.md) --------------------
export CLAUDE_WORKFLOW_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/workflow-plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
CACHE_DIR="$TMPD/cache"; mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/parallelism.conf"
GOLDEN="$TMPD/golden.conf"

REAL_RUN_ALL="${HOME:-/nonexistent}/.claude/run-all"
REAL_PRE=0; [ -e "$REAL_RUN_ALL" ] && REAL_PRE=1

FX="$TMPD/fx"; mkdir -p "$FX"
for i in 1 2 3 4 5; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FX/t$i.sh"; done

BOGUS_HOST="zz-not-this-host|zz-arch|zz-name"
MEASURED_AT="2026-01-02T03:04:05Z"

# --- sentinel installation --------------------------------------------------
CAL_LOG="$TMPD/calibration-invocations.log"; SCRIPT_LOG="$TMPD/bash-scripts.log"

# L1 — the approved measurement seam. Prints a plausible elapsed-ms so that a
# calibrator that DID start would proceed and be recorded rather than hang.
SENT_MEASURE="$TMPD/sentinel-measure.sh"
cat > "$SENT_MEASURE" <<SENT
#!/usr/bin/env bash
printf 'L1-measure %s\n' "\$*" >> "$CAL_LOG"
printf '1000\n'
SENT

# L3 — a PATH shim carrying the calibrator's own name.
SHIM_DIR="$TMPD/shim"; mkdir -p "$SHIM_DIR"
SENT_SHIM="$SHIM_DIR/calibrate-test-parallelism.sh"
cat > "$SENT_SHIM" <<SENT
#!/usr/bin/env bash
printf 'L3-path-shim %s\n' "\$*" >> "$CAL_LOG"
SENT

# L2 — sourced by every non-interactive bash, so it sees the script path even
# when the caller built that path at runtime.
PROBE="$TMPD/bash-env-probe.sh"
cat > "$PROBE" <<PROBE_EOF
printf '%s\n' "\${0:-}" >> "$SCRIPT_LOG" 2>/dev/null
true
PROBE_EOF

chmod +x "$SENT_MEASURE" "$SENT_SHIM" 2>/dev/null || true

# --- drivers ----------------------------------------------------------------
R_OUT=""; R_ERR=""; R_RC=0
# run_runner <cal-env-mode> — a normal `-j auto` run with all sentinels armed.
run_runner() {
    local mode="$1"
    local envs
    envs=("RUN_ALL_CACHE_DIR=$CACHE_DIR" "TESTS_DIR=$FX"
          "RUN_ALL_CALIBRATION_MEASURE_CMD=$SENT_MEASURE"
          "BASH_ENV=$PROBE" "PATH=$SHIM_DIR:$PATH")
    [ "$mode" = "forced" ] && envs+=("RUN_CALIBRATION=1")
    R_RC=0
    : > "$TMPD/stderr.txt"
    R_OUT="$(run_with_timeout 90 env "${envs[@]}" bash "$RUNNER" -j auto "$FX/t1.sh" \
        2>"$TMPD/stderr.txt")" || R_RC=$?
    R_ERR="$(cat "$TMPD/stderr.txt")"
}

reason_token() {
    local t
    t="$(printf '%s\n' "$R_ERR" | sed -n 's/^\[run-all\] parallelism cache \([a-z][a-z-]*\);.*/\1/p' | head -1)"
    [ -z "$t" ] && t="(no-notice)"
    printf '%s' "$t"
}

contract_count() {
    printf '%s\n' "$1" | grep -cE '^[[:space:]]*RUN_CONTRACT: PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+ EXECUTED=[0-9]+' || true
}

# calibrator_traces — every sentinel hit, collapsed to one comparable count.
calibrator_traces() {
    local direct indirect
    direct="$(grep -c . "$CAL_LOG" 2>/dev/null || true)"; direct="${direct:-0}"
    indirect="$(grep -ci 'calibrat' "$SCRIPT_LOG" 2>/dev/null || true)"; indirect="${indirect:-0}"
    printf '%s' "$((direct + indirect))"
}

arm_sentinels() { : > "$CAL_LOG"; : > "$SCRIPT_LOG"; }

gen_cache() {
    printf 'schema=1\nhost_id=%s\ncount_bucket=%s\njobs=6\nmeasured_at=%s\nsample_size=24\nrepeat=3\n' \
        "$1" "$2" "$MEASURED_AT"
}

REAL_HOST=""; REAL_BUCKET=""
lib_eval() {
    [ -f "$LIB" ] || return 1
    run_with_timeout 30 bash -c \
        'set -u; . "$0" >/dev/null 2>&1 || exit 1; eval "$1"' "$LIB" "$1" 2>/dev/null
}
resolve_host() {
    REAL_HOST="$(lib_eval 'run_all_host_id')" || return 1
    REAL_BUCKET="$(lib_eval 'run_all_count_bucket 5')" || return 1
    case "$REAL_BUCKET" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$REAL_HOST" ]
}

# ===========================================================================
# 1. Static augment — the literal-filename grep is kept, but only as a cheap
#    extra; the behavioural matrix below is what actually pins the invariant.
# ===========================================================================
case_static_augment() {
    local hits
    hits="$(grep -cE '(bash|sh|exec|source|^[[:space:]]*\.)[[:space:]]+[^[:space:]]*calibrate-test-parallelism\.sh' \
        "$RUNNER" 2>/dev/null || true)"
    assert_eq "g3-cal/static/runner-has-no-literal-invocation" "0" "$hits"
}

# ===========================================================================
# 2. Behavioural matrix — no cache state makes a normal run calibrate
# ===========================================================================
case_no_auto_calibration() {
    local name state want mode row had inv
    while IFS='|' read -r name state want; do
        name="$(trim "$name")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        state="$(trim "$state")"; want="$(trim "$want")"

        for mode in neutral forced; do
            row="g3-cal/no-auto/$name/$mode"
            rm -f "$CACHE_FILE"
            case "$state" in
                absent)  : ;;
                corrupt) printf 'this is not a key value file\nstill not one\n' > "$CACHE_FILE" ;;
                host)    gen_cache "$BOGUS_HOST" 2 > "$CACHE_FILE" ;;
                bucket)
                    if resolve_host; then
                        gen_cache "$REAL_HOST" "$((REAL_BUCKET + 5))" > "$CACHE_FILE"
                    else
                        for inv in sentinel-never-fired reason fallback-jobs-4 run-exit-zero \
                                   one-contract cache-not-self-healed; do
                            fail "$row/$inv" "implementation missing: $LIB_REL"
                        done
                        continue
                    fi ;;
                *) fail "$row/sentinel-never-fired" "unknown fixture state: $state"; continue ;;
            esac
            had=0
            if [ -e "$CACHE_FILE" ]; then cp "$CACHE_FILE" "$GOLDEN"; had=1; fi

            arm_sentinels
            run_runner "$mode"

            assert_eq "$row/sentinel-never-fired" "0" "$(calibrator_traces)"
            assert_eq "$row/reason" "$want" "$(reason_token)"
            case "$R_ERR" in
                *"using -j 4 (conservative default)"*) pass "$row/fallback-jobs-4" ;;
                *) fail "$row/fallback-jobs-4" "the run must announce the conservative -j 4 fallback" ;;
            esac
            assert_eq "$row/run-exit-zero" "0" "$R_RC"
            assert_eq "$row/one-contract" "1" "$(contract_count "$R_OUT")"

            if [ "$had" -eq 1 ]; then
                if cmp -s "$GOLDEN" "$CACHE_FILE"; then pass "$row/cache-not-self-healed"
                else fail "$row/cache-not-self-healed" "the run rewrote a cache it only had to reject"; fi
            elif [ -e "$CACHE_FILE" ]; then
                fail "$row/cache-not-self-healed" "the run created a cache; only the calibrator may write one"
            else pass "$row/cache-not-self-healed"; fi
        done
    done <<'TABLE'
# name       | cache state              | want reason token
no-cache     | absent                   | missing
corrupt-cache| corrupt                  | malformed
stale-host   | host                     | host-mismatch
stale-bucket | bucket                   | bucket-mismatch
TABLE
}

# ===========================================================================
# 3. Decoy proves the BASH_ENV probe is live (an empty log alone is not proof).
# ===========================================================================
case_probe_is_live() {
    local decoy
    decoy="$TMPD/wrapper-for-calibrate-test-parallelism.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$decoy"
    arm_sentinels
    run_with_timeout 30 env "BASH_ENV=$PROBE" bash "$decoy" >/dev/null 2>&1 || true
    if [ "$(calibrator_traces)" -ge 1 ]; then pass "g3-cal/probe/sentinel-detects-indirect-run"
    else fail "g3-cal/probe/sentinel-detects-indirect-run" \
        "the BASH_ENV probe recorded nothing for a calibrator-named script — every empty-log row above is vacuous"; fi
    arm_sentinels
}

# ===========================================================================
# 4. The calibrator's explicit-run gate, asserted behaviourally
# ===========================================================================
case_explicit_run_gate() {
    local name value rc entries envs
    while IFS='|' read -r name value; do
        name="$(trim "$name")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        value="$(trim "$value")"
        if [ ! -f "$CAL" ]; then
            fail "g3-cal/gate/$name/exits-77" "implementation missing: $CAL_REL"
            fail "g3-cal/gate/$name/writes-nothing" "implementation missing: $CAL_REL"
            fail "g3-cal/gate/$name/never-measures" "implementation missing: $CAL_REL"
            continue
        fi
        rm -f "$CACHE_FILE"
        arm_sentinels
        envs=("RUN_ALL_CACHE_DIR=$CACHE_DIR" "TESTS_DIR=$FX"
              "RUN_ALL_CALIBRATION_MEASURE_CMD=$SENT_MEASURE")
        [ "$value" != "<UNSET>" ] && envs+=("RUN_CALIBRATION=$value")
        rc=0
        run_with_timeout 60 env "${envs[@]}" bash "$CAL" \
            --sample 4 --jobs-list "1 2" --repeat 3 --warmup 0 >/dev/null 2>&1 || rc=$?
        assert_eq "g3-cal/gate/$name/exits-77" "77" "$rc"
        entries="$(ls -A "$CACHE_DIR" 2>/dev/null | tr '\n' ' ')"
        assert_eq "g3-cal/gate/$name/writes-nothing" "" "$entries"
        assert_eq "g3-cal/gate/$name/never-measures" "0" "$(calibrator_traces)"
    done <<'TABLE'
# name            | RUN_CALIBRATION value
unset             | <UNSET>
empty             |
zero              | 0
TABLE
}

# --- 5. The developer's real cache dir was never touched --------------------
case_real_home_untouched() {
    local now=0; [ -e "$REAL_RUN_ALL" ] && now=1
    assert_eq "g3-cal/isolation/real-home-run-all-untouched" "$REAL_PRE" "$now"
}

case_static_augment
case_no_auto_calibration
case_probe_is_live
case_explicit_run_gate
case_real_home_untouched

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
