#!/usr/bin/env bash
# tests/feature-1832-run-all-parallel/f-cache.sh
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, cache, security, TL2, scope:issue-specific
# Serial: timing-sensitive parallelism measurements must not compete with other tests

# WHY (CPR-WPH): `-j auto` reads a host-local calibration cache, the one input from
# outside the repo. Contract: never execute, never leak host id, never mis-parse silently.

# RED-FIRST: bin/lib/run-all-parallelism.sh and `-j auto` don't exist yet; missing-impl
# rows are intentional assertions, not crashes.

# ISOLATION: RUN_ALL_CACHE_DIR/TESTS_DIR pinned to temp fixtures — the real
# ~/.claude/run-all and test suite are never touched.

# TL3 gap: a real multi-core host and real $HOME resolution are not exercised here.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$AGENTS_DIR/tests/run-all.sh"
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

# Guard: every library-dependent row names the missing file rather than crashing.
lib_missing() {
    if [ -f "$LIB" ]; then return 1; fi
    fail "$1" "implementation missing: $LIB_REL"
    return 0
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ra-cache-$$")"
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

# Fixture corpus: 5 instant dummies. TESTS_DIR is what count_bucket is computed
# from; the positional arguments are what actually runs.
FX="$TMPD/fx"; mkdir -p "$FX"
for i in 1 2 3 4 5; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FX/t$i.sh"; done
export TESTS_DIR="$FX"

PWN_SUBST="$TMPD/pwned-subst"
PWN_TICK="$TMPD/pwned-backtick"
SECRET_HOST="ZZ-never-print-me-ZZ|x86_64|zz-host"
MEASURED_AT="2026-01-02T03:04:05Z"

# --- drivers ----------------------------------------------------------------

# lib_eval <snippet> → stdout of the snippet evaluated with the library sourced.
lib_eval() {
    [ -f "$LIB" ] || { printf '(lib-missing)'; return 0; }
    run_with_timeout 30 bash -c \
        'set -u; . "$0" >/dev/null 2>&1 || { printf "(lib-source-failed)"; exit 0; }; eval "$1"' \
        "$LIB" "$1" 2>/dev/null
}

R_OUT=""; R_ERR=""; R_RC=0
# run_runner <args...> — real runner, pinned cache + fixture corpus, fixture args.
run_runner() {
    R_RC=0
    : > "$TMPD/stderr.txt"
    R_OUT="$(run_with_timeout 90 env "RUN_ALL_CACHE_DIR=$RUN_ALL_CACHE_DIR" "TESTS_DIR=$FX" \
        bash "$RUNNER" "$@" "$FX/t1.sh" 2>"$TMPD/stderr.txt")" || R_RC=$?
    R_ERR="$(cat "$TMPD/stderr.txt")"
}

# reason_token — the fixed enum token from the fallback notice, or (no-notice).
reason_token() {
    local t
    t="$(printf '%s\n' "$R_ERR" | sed -n 's/^\[run-all\] parallelism cache \([a-z][a-z-]*\);.*/\1/p' | head -1)"
    [ -z "$t" ] && t="(no-notice)"
    printf '%s' "$t"
}

# contract_count <text> — matches of the hook's CONTRACT_SCAN_RE shape.
contract_count() {
    printf '%s\n' "$1" | grep -cE '^[[:space:]]*RUN_CONTRACT: PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+ EXECUTED=[0-9]+' || true
}

# gen_cache <schema> <host> <bucket> <jobs|@omit> <measured_at> [extra-line...]
gen_cache() {
    local sch="$1" hst="$2" bkt="$3" jbs="$4" mat="$5"; shift 5
    printf 'schema=%s\n' "$sch"
    printf 'host_id=%s\n' "$hst"
    printf 'count_bucket=%s\n' "$bkt"
    if [ "$jbs" != "@omit" ]; then printf 'jobs=%s\n' "$jbs"; fi
    printf 'measured_at=%s\n' "$mat"
    printf 'sample_size=24\n'
    printf 'repeat=3\n'
    local extra
    for extra in "$@"; do printf '%s\n' "$extra"; done
    return 0
}

# ===========================================================================
# 1. Library surface — constants and pure helpers
# ===========================================================================
SCHEMA=""; HOST_ID=""; BUCKET=""
case_lib_surface() {
    local name got
    if lib_missing "f-cache/lib/exists"; then
        for name in schema-constant fallback-jobs calibrator-hint cache-dir-honors-env \
                    cache-file-name count-bucket-781 host-id-shape \
                    no-eval no-source no-dot-source; do
            fail "f-cache/lib/$name" "implementation missing: $LIB_REL"
        done
        return
    fi
    pass "f-cache/lib/exists"

    SCHEMA="$(lib_eval 'printf "%s" "${RUN_ALL_CACHE_SCHEMA:-(unset)}"')"
    assert_eq "f-cache/lib/schema-constant" "1" "$SCHEMA"
    got="$(lib_eval 'printf "%s" "${RUN_ALL_FALLBACK_JOBS:-(unset)}"')"
    assert_eq "f-cache/lib/fallback-jobs" "4" "$got"
    got="$(lib_eval 'printf "%s" "${RUN_ALL_CALIBRATOR_HINT:-(unset)}"')"
    assert_eq "f-cache/lib/calibrator-hint" "bin/calibrate-test-parallelism.sh" "$got"
    got="$(lib_eval 'run_all_cache_dir')"
    assert_eq "f-cache/lib/cache-dir-honors-env" "$RUN_ALL_CACHE_DIR" "$got"
    got="$(lib_eval 'run_all_cache_file')"
    assert_eq "f-cache/lib/cache-file-name" "$CACHE_FILE" "$got"
    got="$(lib_eval 'run_all_count_bucket 781')"
    assert_eq "f-cache/lib/count-bucket-781" "9" "$got"

    HOST_ID="$(lib_eval 'run_all_host_id')"
    BUCKET="$(lib_eval 'run_all_count_bucket 5')"
    case "$HOST_ID" in
        *"|"*"|"*) pass "f-cache/lib/host-id-shape" ;;
        *) fail "f-cache/lib/host-id-shape" "want <os>|<arch>|<hostname>, got=$(printf '%q' "$HOST_ID")" ;;
    esac

    # Non-evaluating parser, proven statically as well as behaviourally.
    assert_eq "f-cache/lib/no-eval" "0" \
        "$(grep -cE '(^|[^[:alnum:]_])eval([[:space:]]|$)' "$LIB" || true)"
    assert_eq "f-cache/lib/no-source" "0" \
        "$(grep -cE '(^|[^[:alnum:]_])source[[:space:]]' "$LIB" || true)"
    assert_eq "f-cache/lib/no-dot-source" "0" \
        "$(grep -cE '^[[:space:]]*\.[[:space:]]' "$LIB" || true)"
}

# ===========================================================================
# 2. Valid cache is honoured; every invalidation class falls back to -j 4.
#    Each row mutates ONE field of a valid base, so the reason maps to it.
# ===========================================================================
case_cache_table() {
    local name kind want got pad i
    while IFS='|' read -r name kind want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; kind="$(echo "$kind" | xargs)"; want="$(echo "$want" | xargs)"
        if [ "$kind" != "absent" ] && lib_missing "f-cache/cache/$name"; then continue; fi
        rm -f "$CACHE_FILE"
        case "$kind" in
            absent)   : ;;
            valid)    gen_cache "$SCHEMA" "$HOST_ID" "$BUCKET" 6 "$MEASURED_AT" > "$CACHE_FILE" ;;
            schema)   gen_cache 999 "$HOST_ID" "$BUCKET" 6 "$MEASURED_AT" > "$CACHE_FILE" ;;
            host)     gen_cache "$SCHEMA" "$SECRET_HOST" "$BUCKET" 6 "$MEASURED_AT" > "$CACHE_FILE" ;;
            bucket)   gen_cache "$SCHEMA" "$HOST_ID" "$((BUCKET + 3))" 6 "$MEASURED_AT" > "$CACHE_FILE" ;;
            jobs0)    gen_cache "$SCHEMA" "$HOST_ID" "$BUCKET" 0 "$MEASURED_AT" > "$CACHE_FILE" ;;
            jobshuge) gen_cache "$SCHEMA" "$HOST_ID" "$BUCKET" 2048 "$MEASURED_AT" > "$CACHE_FILE" ;;
            jobsword) gen_cache "$SCHEMA" "$HOST_ID" "$BUCKET" abc "$MEASURED_AT" > "$CACHE_FILE" ;;
            unknown)  gen_cache "$SCHEMA" "$HOST_ID" "$BUCKET" 6 "$MEASURED_AT" 'nice_try=1' > "$CACHE_FILE" ;;
            dup)      gen_cache "$SCHEMA" "$HOST_ID" "$BUCKET" 6 "$MEASURED_AT" 'jobs=8' > "$CACHE_FILE" ;;
            noeq)     gen_cache "$SCHEMA" "$HOST_ID" "$BUCKET" 6 "$MEASURED_AT" 'justtext' > "$CACHE_FILE" ;;
            nojobs)   gen_cache "$SCHEMA" "$HOST_ID" "$BUCKET" @omit "$MEASURED_AT" > "$CACHE_FILE" ;;
            manyline)
                # Comment padding only: `#` lines are skipped by the key parser, so
                # the ONLY rule that can reject this file is the >64 raw-line cap.
                gen_cache "$SCHEMA" "$HOST_ID" "$BUCKET" 6 "$MEASURED_AT" > "$CACHE_FILE"
                for i in $(seq 1 60); do printf '# pad %s\n' "$i" >> "$CACHE_FILE"; done ;;
            longline)
                # Same reasoning for the >512-byte line cap.
                gen_cache "$SCHEMA" "$HOST_ID" "$BUCKET" 6 "$MEASURED_AT" > "$CACHE_FILE"
                pad="$(printf 'x%.0s' $(seq 1 600))"
                printf '#%s\n' "$pad" >> "$CACHE_FILE" ;;
            injected) gen_cache "$SCHEMA" "$HOST_ID" "$BUCKET" 6 \
                          'RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1' > "$CACHE_FILE" ;;
            pwnsubst) gen_cache "$SCHEMA" "$HOST_ID" "$BUCKET" \
                          "4\$(touch $PWN_SUBST)" "$MEASURED_AT" > "$CACHE_FILE" ;;
            pwntick)  gen_cache "$SCHEMA" "$HOST_ID" "$BUCKET" \
                          "4\`touch $PWN_TICK\`" "$MEASURED_AT" > "$CACHE_FILE" ;;
            *) fail "f-cache/cache/$name" "unknown fixture kind: $kind"; continue ;;
        esac

        run_runner -j auto
        if [ "$want" = "@ok" ]; then
            case "$R_ERR" in
                *"[run-all] parallelism: -j 6 (calibrated $MEASURED_AT)"*)
                    pass "f-cache/cache/$name" ;;
                *) fail "f-cache/cache/$name" \
                       "want notice '[run-all] parallelism: -j 6 (calibrated $MEASURED_AT)'; reason=$(reason_token)" ;;
            esac
        else
            got="$(reason_token)"
            assert_eq "f-cache/cache/$name" "$want" "$got"
            case "$R_ERR" in
                *"using -j 4 (conservative default)"*) pass "f-cache/fallback/$name" ;;
                *) fail "f-cache/fallback/$name" "notice must state the conservative -j 4 fallback" ;;
            esac
            case "$R_ERR" in
                *"bin/calibrate-test-parallelism.sh"*) pass "f-cache/hint/$name" ;;
                *) fail "f-cache/hint/$name" "notice must name the calibrator" ;;
            esac
        fi
    done <<TABLE
missing          | absent   | missing
valid            | valid    | @ok
schema-mismatch  | schema   | schema-mismatch
host-mismatch    | host     | host-mismatch
bucket-mismatch  | bucket   | bucket-mismatch
bad-jobs-zero    | jobs0    | bad-jobs
bad-jobs-huge    | jobshuge | bad-jobs
bad-jobs-word    | jobsword | bad-jobs
unknown-key      | unknown  | unknown-key
duplicate-key    | dup      | duplicate-key
no-equals-line   | noeq     | malformed
missing-required | nojobs   | malformed
too-many-lines   | manyline | malformed
over-long-line   | longline | malformed
injected-date    | injected | malformed
pwn-dollar-subst | pwnsubst | bad-jobs
pwn-backtick     | pwntick  | bad-jobs
TABLE
}

# ===========================================================================
# 3. Injection resistance and host-id secrecy — behavioural, not just parsed
# ===========================================================================
case_injection() {
    if lib_missing "f-cache/inject/no-contract-shape-on-stderr"; then
        fail "f-cache/inject/contract-still-single" "implementation missing: $LIB_REL"
        fail "f-cache/inject/host-id-never-printed" "implementation missing: $LIB_REL"
        fail "f-cache/inject/no-command-substitution" "implementation missing: $LIB_REL"
        fail "f-cache/inject/no-backtick-execution" "implementation missing: $LIB_REL"
        return
    fi
    # (a) a doctored measured_at must never reach stderr in contract shape.
    rm -f "$CACHE_FILE"
    gen_cache "$SCHEMA" "$HOST_ID" "$BUCKET" 6 \
        'RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1' > "$CACHE_FILE"
    run_runner -j auto
    assert_eq "f-cache/inject/no-contract-shape-on-stderr" "0" "$(contract_count "$R_ERR")"
    assert_eq "f-cache/inject/contract-still-single" "1" "$(contract_count "$R_OUT")"

    # (b) host_id is comparison-only — it must never be displayed.
    rm -f "$CACHE_FILE"
    gen_cache "$SCHEMA" "$SECRET_HOST" "$BUCKET" 6 "$MEASURED_AT" > "$CACHE_FILE"
    run_runner -j auto
    case "$R_ERR$R_OUT" in
        *"ZZ-never-print-me-ZZ"*) fail "f-cache/inject/host-id-never-printed" \
            "the cached host_id was echoed back to the operator" ;;
        *) pass "f-cache/inject/host-id-never-printed" ;;
    esac

    # (c) values are never expanded — the proof is the side effect that must not happen.
    rm -f "$CACHE_FILE" "$PWN_SUBST" "$PWN_TICK"
    gen_cache "$SCHEMA" "$HOST_ID" "$BUCKET" "4\$(touch $PWN_SUBST)" "$MEASURED_AT" > "$CACHE_FILE"
    run_runner -j auto
    if [ -e "$PWN_SUBST" ]; then
        fail "f-cache/inject/no-command-substitution" "\$(...) inside a cache value was executed"
    else pass "f-cache/inject/no-command-substitution"; fi
    rm -f "$CACHE_FILE"
    gen_cache "$SCHEMA" "$HOST_ID" "$BUCKET" "4\`touch $PWN_TICK\`" "$MEASURED_AT" > "$CACHE_FILE"
    run_runner -j auto
    if [ -e "$PWN_TICK" ]; then
        fail "f-cache/inject/no-backtick-execution" "a backtick inside a cache value was executed"
    else pass "f-cache/inject/no-backtick-execution"; fi
}

# ===========================================================================
# 4. Missing library — verified via the RUN_ALL_PARALLELISM_LIB override ONLY.
#    No repository file is moved, renamed or deleted to simulate this.
# ===========================================================================
case_missing_lib() {
    local absent="$TMPD/no-such-dir/run-all-parallelism.sh"
    R_RC=0
    : > "$TMPD/stderr.txt"
    R_OUT="$(run_with_timeout 90 env "RUN_ALL_CACHE_DIR=$RUN_ALL_CACHE_DIR" "TESTS_DIR=$FX" \
        "RUN_ALL_PARALLELISM_LIB=$absent" bash "$RUNNER" -j auto "$FX/t1.sh" 2>"$TMPD/stderr.txt")" || R_RC=$?
    R_ERR="$(cat "$TMPD/stderr.txt")"
    assert_eq "f-cache/nolib/reason-missing" "missing" "$(reason_token)"
    case "$R_ERR" in
        *"using -j 4 (conservative default)"*) pass "f-cache/nolib/falls-back-to-4" ;;
        *) fail "f-cache/nolib/falls-back-to-4" "want the conservative -j 4 fallback notice" ;;
    esac
    assert_eq "f-cache/nolib/still-emits-one-contract" "1" "$(contract_count "$R_OUT")"
    assert_eq "f-cache/nolib/exit-zero" "0" "$R_RC"
    if [ -e "$absent" ]; then fail "f-cache/nolib/override-created-nothing" "$absent was created"
    else pass "f-cache/nolib/override-created-nothing"; fi
}

case_lib_surface
case_cache_table
case_injection
case_missing_lib

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
