#!/usr/bin/env bash
# tests/tests/feature-1832-run-all-parallel/f-cache.sh
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, cache, security, TL2, scope:issue-specific, lanes-status
# Serial: timing-sensitive parallelism measurements must not compete with other tests
# WHY (CPR-WPH): the measured record is the one input from outside the repo. Contract: never
# execute, never leak host id, never mis-parse silently. #2079: the runner no longer reads it, so
# the entry point is line 1 of bin/test-lanes-status.sh. ISOLATION: temp RUN_ALL_CACHE_DIR, a
# uname stub, absent RUN_ALL_CONFIG_VAR_CMD. TL3 gap: a real multi-core host and real $HOME.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUNNER="$AGENTS_DIR/tests/run-all.sh"
STATUS="$AGENTS_DIR/bin/test-lanes-status.sh"
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
unset CLAUDE_CODE_SESSION_ID
unset TEST_MAX_JOBS_PER_RUN TEST_MAX_JOBS_PER_HOST TEST_LANES TEST_LANES_HELD
export RUN_ALL_CACHE_DIR="$TMPD/cache"
mkdir -p "$RUN_ALL_CACHE_DIR"
CACHE_FILE="$RUN_ALL_CACHE_DIR/parallelism.conf"
NO_CFG="$TMPD/absent-get-config-var"

FX="$TMPD/fx"; mkdir -p "$FX"
for i in 1 2 3 4 5; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FX/t$i.sh"; done

PWN_SUBST="$TMPD/pwned-subst"
PWN_TICK="$TMPD/pwned-backtick"
PWN_OS="$TMPD/pwned-os"
SECRET_HOST="ZZ-never-print-me-ZZ|x86_64|zz-host"
MEASURED_AT="2026-01-02T03:04:05Z"

# The uname stub answers each flag from F_STUB_*, so every row pins one host exactly.
mkdir -p "$TMPD/stubbin"
printf '%s\n' '#!/bin/sh' 'case "${1:-}" in' '  -m) printf "%s\n" "$F_STUB_M" ;;' \
    '  -n) printf "%s\n" "$F_STUB_N" ;;' '  -r) printf "%s\n" "$F_STUB_R" ;;' \
    '  *)  printf "%s\n" "$F_STUB_S" ;;' 'esac' > "$TMPD/stubbin/uname"
chmod +x "$TMPD/stubbin/uname"
W26300="MINGW64_NT-10.0-26300"
STUB_S="$W26300"
# stub_env — fills SE (an array, since an ambient PATH may itself hold newlines).
SE=()
stub_env() {
    SE=("PATH=$TMPD/stubbin:$PATH" "HOSTNAME=stubhost" "F_STUB_S=$STUB_S"
        "F_STUB_M=x86_64" "F_STUB_N=stubhost" "F_STUB_R=3.5.4-0.x86_64")
}

# lib_eval <snippet> → stdout of the snippet, library sourced, under the current stub.
lib_eval() {
    [ -f "$LIB" ] || { printf '(lib-missing)'; return 0; }
    stub_env
    run_with_timeout 30 env "${SE[@]}" bash -c \
        'set -u; . "$0" >/dev/null 2>&1 || { printf "(lib-source-failed)"; exit 0; }; eval "$1"' \
        "$LIB" "$1" 2>/dev/null
}

# status_run — the read-only status tool under the current stub; S_LINE is its first line.
S_OUT=""; S_ERR=""; S_RC=0; S_LINE=""
status_run() {
    stub_env
    S_RC=0
    : > "$TMPD/status.err"
    S_OUT="$(run_with_timeout 30 env "${SE[@]}" "RUN_ALL_CACHE_DIR=$RUN_ALL_CACHE_DIR" \
        "RUN_ALL_CONFIG_VAR_CMD=$NO_CFG" bash "$STATUS" 2>"$TMPD/status.err")" || S_RC=$?
    S_ERR="$(cat "$TMPD/status.err")"
    S_LINE="$(printf '%s\n' "$S_OUT" | head -n 1)"
}

contract_count() {
    printf '%s\n' "$1" | grep -cE '^[[:space:]]*RUN_CONTRACT: PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+ EXECUTED=[0-9]+' || true
}

# gen_rec <schema> <host> <os|@omit> <max|@omit> <measured_at> [extra-line...] — a v2-shaped record.
gen_rec() {
    local sch="$1" hst="$2" os="$3" mx="$4" mat="$5" extra; shift 5
    printf 'schema=%s\nhost_id=%s\n' "$sch" "$hst"
    [ "$os" = "@omit" ] || printf 'os=%s\n' "$os"
    [ "$mx" = "@omit" ] || printf 'max_jobs_per_host=%s\n' "$mx"
    printf 'measured_at=%s\nsample_size=24\nrepeat=3\n' "$mat"
    for extra in "$@"; do printf '%s\n' "$extra"; done
    return 0
}

# ===========================================================================
# 1. Library surface — constants, removed helpers, static non-evaluation
# ===========================================================================
HOST_ID=""; OS_ATTR=""
case_lib_surface() {
    local name got
    if lib_missing "f-cache/lib/exists"; then
        for name in schema-constant default-per-run default-per-host fallback-removed calibrator-hint \
                    cache-dir-honors-env cache-file-name bucket-helpers-removed host-id-shape os-attr \
                    no-eval no-source no-dot-source; do
            fail "f-cache/lib/$name" "implementation missing: $LIB_REL"
        done
        return
    fi
    pass "f-cache/lib/exists"
    assert_eq "f-cache/lib/schema-constant" "2" "$(lib_eval 'printf "%s" "${RUN_ALL_CACHE_SCHEMA:-(unset)}"')"
    assert_eq "f-cache/lib/default-per-run" "4" \
        "$(lib_eval 'printf "%s" "${RUN_ALL_DEFAULT_MAX_JOBS_PER_RUN:-(unset)}"')"
    assert_eq "f-cache/lib/default-per-host" "4" \
        "$(lib_eval 'printf "%s" "${RUN_ALL_DEFAULT_MAX_JOBS_PER_HOST:-(unset)}"')"
    assert_eq "f-cache/lib/fallback-removed" "(unset)" "$(lib_eval 'printf "%s" "${RUN_ALL_FALLBACK_JOBS:-(unset)}"')"
    assert_eq "f-cache/lib/calibrator-hint" "bin/calibrate-test-parallelism.sh" \
        "$(lib_eval 'printf "%s" "${RUN_ALL_CALIBRATOR_HINT:-(unset)}"')"
    assert_eq "f-cache/lib/cache-dir-honors-env" "$RUN_ALL_CACHE_DIR" "$(lib_eval 'run_all_cache_dir')"
    assert_eq "f-cache/lib/cache-file-name" "$CACHE_FILE" "$(lib_eval 'run_all_cache_file')"
    got="$(lib_eval 'for f in run_all_count_bucket run_all_corpus_count run_all_corpus_bucket; do declare -F "$f"; done; printf none')"
    assert_eq "f-cache/lib/bucket-helpers-removed" "none" "$got"

    HOST_ID="$(lib_eval 'run_all_host_id')"
    OS_ATTR="$(lib_eval 'run_all_os_attr')"
    case "$HOST_ID" in
        "Windows|"*"|"*) pass "f-cache/lib/host-id-shape" ;;
        *) fail "f-cache/lib/host-id-shape" "want Windows|<arch>|<digest> under $STUB_S, got=$(printf '%q' "$HOST_ID")" ;;
    esac
    assert_eq "f-cache/lib/os-attr" "Windows/10.0.26300" "$OS_ATTR"

    assert_eq "f-cache/lib/no-eval" "0" "$(grep -cE '(^|[^[:alnum:]_])eval([[:space:]]|$)' "$LIB" || true)"
    assert_eq "f-cache/lib/no-source" "0" "$(grep -cE '(^|[^[:alnum:]_])source[[:space:]]' "$LIB" || true)"
    assert_eq "f-cache/lib/no-dot-source" "0" "$(grep -cE '^[[:space:]]*\.[[:space:]]' "$LIB" || true)"
}

# ===========================================================================
# 2. A valid record is `source=measured`; every rejection is `source=default record=<token>`
#    with the default 4. Each row mutates ONE field of a valid base.
# ===========================================================================
case_cache_table() {
    local name kind want pad i
    while IFS='|' read -r name kind want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; kind="$(echo "$kind" | xargs)"; want="$(echo "$want" | xargs)"
        if [ "$kind" != "absent" ] && lib_missing "f-cache/cache/$name"; then continue; fi
        rm -f "$CACHE_FILE"
        case "$kind" in
            absent)   : ;;
            valid)    gen_rec 2 "$HOST_ID" "$OS_ATTR" 6 "$MEASURED_AT" > "$CACHE_FILE" ;;
            v1)       printf 'schema=1\nhost_id=%s\ncount_bucket=1\njobs=6\nmeasured_at=%s\nsample_size=24\nrepeat=3\n' \
                          "$HOST_ID" "$MEASURED_AT" > "$CACHE_FILE" ;;
            schema)   gen_rec 999 "$HOST_ID" "$OS_ATTR" 6 "$MEASURED_AT" > "$CACHE_FILE" ;;
            host)     gen_rec 2 "$SECRET_HOST" "$OS_ATTR" 6 "$MEASURED_AT" > "$CACHE_FILE" ;;
            max0)     gen_rec 2 "$HOST_ID" "$OS_ATTR" 0 "$MEASURED_AT" > "$CACHE_FILE" ;;
            maxhuge)  gen_rec 2 "$HOST_ID" "$OS_ATTR" 2048 "$MEASURED_AT" > "$CACHE_FILE" ;;
            maxword)  gen_rec 2 "$HOST_ID" "$OS_ATTR" abc "$MEASURED_AT" > "$CACHE_FILE" ;;
            osshape)  gen_rec 2 "$HOST_ID" "Windows 10.0" 6 "$MEASURED_AT" > "$CACHE_FILE" ;;
            osomit)   gen_rec 2 "$HOST_ID" @omit 6 "$MEASURED_AT" > "$CACHE_FILE" ;;
            unknown)  gen_rec 2 "$HOST_ID" "$OS_ATTR" 6 "$MEASURED_AT" 'nice_try=1' > "$CACHE_FILE" ;;
            oldbkt)   gen_rec 2 "$HOST_ID" "$OS_ATTR" 6 "$MEASURED_AT" 'count_bucket=1' > "$CACHE_FILE" ;;
            oldjobs)  gen_rec 2 "$HOST_ID" "$OS_ATTR" 6 "$MEASURED_AT" 'jobs=6' > "$CACHE_FILE" ;;
            dup)      gen_rec 2 "$HOST_ID" "$OS_ATTR" 6 "$MEASURED_AT" 'max_jobs_per_host=8' > "$CACHE_FILE" ;;
            noeq)     gen_rec 2 "$HOST_ID" "$OS_ATTR" 6 "$MEASURED_AT" 'justtext' > "$CACHE_FILE" ;;
            nomax)    gen_rec 2 "$HOST_ID" "$OS_ATTR" @omit "$MEASURED_AT" > "$CACHE_FILE" ;;
            manyline)
                # `#` lines are skipped by the key parser, so only the >64 raw-line cap can reject this.
                gen_rec 2 "$HOST_ID" "$OS_ATTR" 6 "$MEASURED_AT" > "$CACHE_FILE"
                for i in $(seq 1 60); do printf '# pad %s\n' "$i" >> "$CACHE_FILE"; done ;;
            longline)
                gen_rec 2 "$HOST_ID" "$OS_ATTR" 6 "$MEASURED_AT" > "$CACHE_FILE"
                pad="$(printf 'x%.0s' $(seq 1 600))"
                printf '#%s\n' "$pad" >> "$CACHE_FILE" ;;
            injected) gen_rec 2 "$HOST_ID" "$OS_ATTR" 6 'RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1' > "$CACHE_FILE" ;;
            pwnsubst) gen_rec 2 "$HOST_ID" "$OS_ATTR" "4\$(touch $PWN_SUBST)" "$MEASURED_AT" > "$CACHE_FILE" ;;
            pwntick)  gen_rec 2 "$HOST_ID" "$OS_ATTR" "4\`touch $PWN_TICK\`" "$MEASURED_AT" > "$CACHE_FILE" ;;
            *) fail "f-cache/cache/$name" "unknown fixture kind: $kind"; continue ;;
        esac

        status_run
        if [ "$want" = "@ok" ]; then
            assert_eq "f-cache/cache/$name" "max_jobs_per_host=6 source=measured" "$S_LINE"
        else
            assert_eq "f-cache/cache/$name" "max_jobs_per_host=4 source=default record=$want" "$S_LINE"
        fi
        assert_eq "f-cache/exit/$name" "0" "$S_RC"
    done <<TABLE
missing            | absent   | missing
valid              | valid    | @ok
schema-v1          | v1       | schema-mismatch
schema-999         | schema   | schema-mismatch
host-mismatch      | host     | host-mismatch
bad-max-zero       | max0     | bad-max-jobs-per-host
bad-max-huge       | maxhuge  | bad-max-jobs-per-host
bad-max-word       | maxword  | bad-max-jobs-per-host
bad-os-shape       | osshape  | bad-os
bad-os-missing     | osomit   | bad-os
unknown-key        | unknown  | unknown-key
unknown-old-bucket | oldbkt   | unknown-key
unknown-old-jobs   | oldjobs  | unknown-key
duplicate-key      | dup      | duplicate-key
no-equals-line     | noeq     | malformed
missing-required   | nomax    | malformed
too-many-lines     | manyline | malformed
over-long-line     | longline | malformed
injected-date      | injected | malformed
pwn-dollar-subst   | pwnsubst | bad-max-jobs-per-host
pwn-backtick       | pwntick  | bad-max-jobs-per-host
TABLE
}

# ===========================================================================
# 3. Injection resistance and secrecy — only the shape-checked `os` may surface.
# ===========================================================================
case_injection() {
    local name v
    if lib_missing "f-cache/inject/exists"; then
        for name in no-contract-shape host-id-never-printed measured-at-never-printed \
                    no-command-substitution no-backtick-execution os-semicolon os-control; do
            fail "f-cache/inject/$name" "implementation missing: $LIB_REL"
        done
        return
    fi
    gen_rec 2 "$HOST_ID" "$OS_ATTR" 6 'RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1' > "$CACHE_FILE"
    status_run
    assert_eq "f-cache/inject/no-contract-shape" "0" "$(contract_count "$S_OUT$S_ERR")"

    gen_rec 2 "$SECRET_HOST" "$OS_ATTR" 6 "$MEASURED_AT" > "$CACHE_FILE"
    status_run
    case "$S_OUT$S_ERR" in
        *"ZZ-never-print-me-ZZ"*) fail "f-cache/inject/host-id-never-printed" "the record's host_id was echoed" ;;
        *) pass "f-cache/inject/host-id-never-printed" ;;
    esac
    gen_rec 2 "$HOST_ID" "$OS_ATTR" 6 "$MEASURED_AT" > "$CACHE_FILE"
    status_run
    case "$S_OUT$S_ERR" in
        *"$MEASURED_AT"*|*"$HOST_ID"*) fail "f-cache/inject/measured-at-never-printed" "a non-os record value was echoed" ;;
        *) pass "f-cache/inject/measured-at-never-printed" ;;
    esac

    rm -f "$PWN_SUBST" "$PWN_TICK" "$PWN_OS"
    gen_rec 2 "$HOST_ID" "$OS_ATTR" "4\$(touch $PWN_SUBST)" "$MEASURED_AT" > "$CACHE_FILE"; status_run
    if [ -e "$PWN_SUBST" ]; then fail "f-cache/inject/no-command-substitution" "\$(...) in a value ran"
    else pass "f-cache/inject/no-command-substitution"; fi
    gen_rec 2 "$HOST_ID" "$OS_ATTR" "4\`touch $PWN_TICK\`" "$MEASURED_AT" > "$CACHE_FILE"; status_run
    if [ -e "$PWN_TICK" ]; then fail "f-cache/inject/no-backtick-execution" "a backtick in a value ran"
    else pass "f-cache/inject/no-backtick-execution"; fi

    # `os` is the one value that may be shown, so a hostile one must be refused, not echoed.
    gen_rec 2 "$HOST_ID" "Windows/10.0;touch $PWN_OS" 6 "$MEASURED_AT" > "$CACHE_FILE"; status_run
    v="$S_LINE"
    case "$S_OUT$S_ERR" in *"touch"*) v="$v (echoed)" ;; esac
    [ -e "$PWN_OS" ] && v="$v (executed)"
    assert_eq "f-cache/inject/os-semicolon" "max_jobs_per_host=4 source=default record=bad-os" "$v"
    gen_rec 2 "$HOST_ID" "$(printf 'Windows/10.0\033[2Jzz')" 6 "$MEASURED_AT" > "$CACHE_FILE"; status_run
    v="$S_LINE"
    case "$S_OUT$S_ERR" in *"zz"*|*$'\033'*) v="$v (echoed)" ;; esac
    assert_eq "f-cache/inject/os-control" "max_jobs_per_host=4 source=default record=bad-os" "$v"
}

# ===========================================================================
# 4. Host identity join and the OS-version advice (#2079 S6/S9).
# ===========================================================================
case_host_join() {
    local host os
    if lib_missing "f-cache/join/exists"; then
        for host in msys-reads-mingw version-advice same-version-no-advice linux-host-mismatch; do
            fail "f-cache/join/$host" "implementation missing: $LIB_REL"
        done
        return
    fi
    STUB_S="$W26300"; host="$(lib_eval 'run_all_host_id')"; os="$(lib_eval 'run_all_os_attr')"
    gen_rec 2 "$host" "$os" 6 "$MEASURED_AT" > "$CACHE_FILE"

    STUB_S="MSYS_NT-10.0-26300"; status_run
    assert_eq "f-cache/join/msys-reads-mingw" "max_jobs_per_host=6 source=measured" "$S_LINE"
    assert_eq "f-cache/join/same-version-no-advice" "0" "$(printf '%s\n' "$S_LINE" | grep -c 'measured_on=' || true)"
    STUB_S="MSYS_NT-10.0-26400"; status_run
    assert_eq "f-cache/join/version-advice" \
        "max_jobs_per_host=6 source=measured measured_on=Windows/10.0.26300 now=Windows/10.0.26400" "$S_LINE"
    STUB_S="Linux"; status_run
    assert_eq "f-cache/join/linux-host-mismatch" "max_jobs_per_host=4 source=default record=host-mismatch" "$S_LINE"
    STUB_S="$W26300"
}

# ===========================================================================
# 5. Missing library — via the RUN_ALL_PARALLELISM_LIB override ONLY; no repo file moves.
# ===========================================================================
case_missing_lib() {
    local absent="$TMPD/no-such-dir/run-all-parallelism.sh" out err rc=0
    : > "$TMPD/stderr.txt"
    out="$(run_with_timeout 90 env "RUN_ALL_CACHE_DIR=$RUN_ALL_CACHE_DIR" "TESTS_DIR=$FX" \
        "RUN_ALL_CONFIG_VAR_CMD=$NO_CFG" "RUN_ALL_PARALLELISM_LIB=$absent" \
        bash "$RUNNER" -j auto "$FX/t1.sh" 2>"$TMPD/stderr.txt")" || rc=$?
    err="$(cat "$TMPD/stderr.txt")"
    case "$err" in
        *"parallelism library unavailable; max jobs per run 4 (built-in default)"*) pass "f-cache/nolib/notice" ;;
        *) fail "f-cache/nolib/notice" "want 'parallelism library unavailable; max jobs per run 4 (built-in default)'" ;;
    esac
    assert_eq "f-cache/nolib/still-emits-one-contract" "1" "$(contract_count "$out")"
    assert_eq "f-cache/nolib/exit-zero" "0" "$rc"
    if [ -e "$absent" ]; then fail "f-cache/nolib/override-created-nothing" "$absent was created"
    else pass "f-cache/nolib/override-created-nothing"; fi
}

case_lib_surface
case_cache_table
case_injection
case_host_join
case_missing_lib

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
