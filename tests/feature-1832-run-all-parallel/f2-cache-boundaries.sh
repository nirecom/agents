#!/usr/bin/env bash
# tests/feature-1832-run-all-parallel/f2-cache-boundaries.sh
# Tests: tests/run-all.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, cache, boundary, off-by-one, TL2, scope:issue-specific
# Serial: timing-sensitive parallelism measurements must not compete with other tests

# WHY (CPR-WPH): sibling f-cache.sh proves each rejection class exists but can't see
# an off-by-one, so every numeric limit here is asserted from BOTH sides (last accepted, first rejected).

# RED-FIRST: bin/lib/run-all-parallelism.sh and `-j auto` don't exist yet; missing-impl
# rows are intentional assertions, not crashes.

# ISOLATION: RUN_ALL_CACHE_DIR/TESTS_DIR pinned to temp fixtures — the real
# suite and ~/.claude/run-all are never reachable.

# TL3 gap: a host genuinely owning 1024 job slots, and live re-bucketing past 512 files, are not exercised here.

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
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

lib_missing() {
    if [ -f "$LIB" ]; then return 1; fi
    fail "$1" "implementation missing: $LIB_REL"
    return 0
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ra-bnd-$$")"
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

REAL_RUN_ALL="${HOME:-/nonexistent}/.claude/run-all"
REAL_PRE=0; [ -e "$REAL_RUN_ALL" ] && REAL_PRE=1

# Small corpus for the numeric-limit rows; their caches always carry the bucket
# this corpus resolves to, so only the numeric field under test can reject them.
FX="$TMPD/fx"; mkdir -p "$FX"
for i in 1 2 3 4 5; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FX/t$i.sh"; done
export TESTS_DIR="$FX"

# Corpus grown in place to 511 / 512 / 1023 / 1024 files by the bucket case.
BFX="$TMPD/bfx"; mkdir -p "$BFX"
BFX_N=0

MEASURED_AT="2026-01-02T03:04:05Z"

# --- drivers ----------------------------------------------------------------

lib_eval() {
    [ -f "$LIB" ] || { printf '(lib-missing)'; return 0; }
    run_with_timeout 30 bash -c \
        'set -u; . "$0" >/dev/null 2>&1 || { printf "(lib-source-failed)"; exit 0; }; eval "$1"' \
        "$LIB" "$1" 2>/dev/null
}

R_OUT=""; R_ERR=""; R_RC=0
# run_runner <tests-dir> <corpus-file> — real runner, pinned cache, fixture args.
run_runner() {
    local tdir="$1" one="$2"
    R_RC=0
    : > "$TMPD/stderr.txt"
    R_OUT="$(run_with_timeout 90 env "RUN_ALL_CACHE_DIR=$RUN_ALL_CACHE_DIR" "TESTS_DIR=$tdir" \
        bash "$RUNNER" -j auto "$one" 2>"$TMPD/stderr.txt")" || R_RC=$?
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

# gen_cache <schema> <host> <bucket> <jobs> <measured_at> — exactly the 7 keys.
gen_cache() {
    printf 'schema=%s\nhost_id=%s\ncount_bucket=%s\njobs=%s\nmeasured_at=%s\nsample_size=24\nrepeat=3\n' \
        "$1" "$2" "$3" "$4" "$5"
}

# assert_accepted <name> <jobs> / assert_rejected <name> <reason> — the honoured
# notice must name that exact width; a rejection must name the enum token AND the
# conservative -j 4 fallback, since a wrong reason on a right fallback is a defect.
assert_accepted() {
    local name="$1" jobs="$2"
    case "$R_ERR" in
        *"[run-all] parallelism: -j $jobs (calibrated $MEASURED_AT)"*) pass "$name" ;;
        *) fail "$name" \
               "want notice '[run-all] parallelism: -j $jobs (calibrated $MEASURED_AT)'; reason=$(reason_token)" ;;
    esac
}
assert_rejected() {
    local name="$1" want="$2"
    assert_eq "$name/reason" "$want" "$(reason_token)"
    case "$R_ERR" in
        *"using -j 4 (conservative default)"*) pass "$name/fallback-jobs-4" ;;
        *) fail "$name/fallback-jobs-4" "notice must state the conservative -j 4 fallback" ;;
    esac
}

SCHEMA=""; HOST_ID=""; BUCKET=""

# ===========================================================================
# 1. The fallback width constant itself — 4 is asserted, not assumed
# ===========================================================================
case_preamble() {
    if lib_missing "f2-cache/preamble/fallback-jobs-is-4"; then
        fail "f2-cache/preamble/schema-is-1" "implementation missing: $LIB_REL"
        return
    fi
    assert_eq "f2-cache/preamble/fallback-jobs-is-4" "4" \
        "$(lib_eval 'printf "%s" "${RUN_ALL_FALLBACK_JOBS:-(unset)}"')"
    SCHEMA="$(lib_eval 'printf "%s" "${RUN_ALL_CACHE_SCHEMA:-(unset)}"')"
    assert_eq "f2-cache/preamble/schema-is-1" "1" "$SCHEMA"
    HOST_ID="$(lib_eval 'run_all_host_id')"
    BUCKET="$(lib_eval 'run_all_count_bucket 5')"
}

# ===========================================================================
# 2. count_bucket = floor(log2(count)) — asserted as a pure function.
#    511/512 separate floor from ceil; only the pair proves which formula runs.
# ===========================================================================
case_bucket_formula() {
    local name count want got
    while IFS='|' read -r name count want; do
        name="$(trim "$name")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        count="$(trim "$count")"; want="$(trim "$want")"
        if lib_missing "f2-cache/bucket-fn/$name"; then continue; fi
        got="$(lib_eval "run_all_count_bucket $count")"
        assert_eq "f2-cache/bucket-fn/$name" "$want" "$got"
    done <<'TABLE'
# name       | count | want floor(log2(count))
count-1      | 1     | 0
count-2      | 2     | 1
count-3      | 3     | 1
count-4      | 4     | 2
count-511    | 511   | 8
count-512    | 512   | 9
count-1023   | 1023  | 9
count-1024   | 1024  | 10
TABLE
}

# ===========================================================================
# 3. Numeric limits, both sides of every edge, through the real runner.
#    padlines are `#` lines (skipped by the parser); linelen excludes the newline.
# ===========================================================================
case_numeric_limits() {
    local name jobs padlines linelen want i pad
    while IFS='|' read -r name jobs padlines linelen want; do
        name="$(trim "$name")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        jobs="$(trim "$jobs")"; padlines="$(trim "$padlines")"
        linelen="$(trim "$linelen")"; want="$(trim "$want")"
        if lib_missing "f2-cache/limit/$name"; then continue; fi

        rm -f "$CACHE_FILE"
        gen_cache "$SCHEMA" "$HOST_ID" "$BUCKET" "$jobs" "$MEASURED_AT" > "$CACHE_FILE"
        i=1
        while [ "$i" -le "$padlines" ]; do printf '# pad %s\n' "$i" >> "$CACHE_FILE"; i=$((i + 1)); done
        if [ "$linelen" -gt 0 ]; then
            pad="$(printf 'x%.0s' $(seq 1 $((linelen - 1))))"
            printf '#%s\n' "$pad" >> "$CACHE_FILE"
        fi

        run_runner "$FX" "$FX/t1.sh"
        if [ "$want" = "@ok" ]; then
            assert_accepted "f2-cache/limit/$name" "$jobs"
        else
            assert_rejected "f2-cache/limit/$name" "$want"
        fi
        assert_eq "f2-cache/limit/$name/one-contract" "1" "$(contract_count "$R_OUT")"
    done <<'TABLE'
# name          | jobs | padlines | linelen | want
jobs-0          | 0    | 0        | 0       | bad-jobs
jobs-1          | 1    | 0        | 0       | @ok
jobs-1024       | 1024 | 0        | 0       | @ok
jobs-1025       | 1025 | 0        | 0       | bad-jobs
lines-64        | 6    | 57       | 0       | @ok
lines-65        | 6    | 58       | 0       | malformed
line-length-512 | 6    | 0        | 512     | @ok
line-length-513 | 6    | 0        | 513     | malformed
TABLE
}

# ===========================================================================
# 4. count_bucket transitions end-to-end: matching bucket in, neighbours out
# ===========================================================================

# grow_bfx <n> — extend the shared corpus to exactly n files, never shrinking it.
grow_bfx() {
    local n="$1"
    while [ "$BFX_N" -lt "$n" ]; do
        BFX_N=$((BFX_N + 1))
        printf '#!/usr/bin/env bash\nexit 0\n' > "$BFX/b$BFX_N.sh"
    done
}

case_bucket_transitions() {
    local name count want got lo hi
    while IFS='|' read -r name count want; do
        name="$(trim "$name")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        count="$(trim "$count")"; want="$(trim "$want")"
        grow_bfx "$count"
        got="$(ls -1 "$BFX"/*.sh 2>/dev/null | grep -c . || true)"
        assert_eq "f2-cache/bucket-corpus/$name/file-count" "$count" "$got"
        if lib_missing "f2-cache/bucket-e2e/$name/matching-accepted"; then
            fail "f2-cache/bucket-e2e/$name/lower-neighbour-rejected" "implementation missing: $LIB_REL"
            fail "f2-cache/bucket-e2e/$name/upper-neighbour-rejected" "implementation missing: $LIB_REL"
            continue
        fi

        rm -f "$CACHE_FILE"
        gen_cache "$SCHEMA" "$HOST_ID" "$want" 6 "$MEASURED_AT" > "$CACHE_FILE"
        run_runner "$BFX" "$BFX/b1.sh"
        assert_accepted "f2-cache/bucket-e2e/$name/matching-accepted" 6

        lo=$((want - 1)); hi=$((want + 1))
        rm -f "$CACHE_FILE"
        gen_cache "$SCHEMA" "$HOST_ID" "$lo" 6 "$MEASURED_AT" > "$CACHE_FILE"
        run_runner "$BFX" "$BFX/b1.sh"
        assert_rejected "f2-cache/bucket-e2e/$name/lower-neighbour-rejected" bucket-mismatch

        rm -f "$CACHE_FILE"
        gen_cache "$SCHEMA" "$HOST_ID" "$hi" 6 "$MEASURED_AT" > "$CACHE_FILE"
        run_runner "$BFX" "$BFX/b1.sh"
        assert_rejected "f2-cache/bucket-e2e/$name/upper-neighbour-rejected" bucket-mismatch
    done <<'TABLE'
# name        | test-file count | want count_bucket
at-511        | 511             | 8
at-512        | 512             | 9
at-1023       | 1023            | 9
at-1024       | 1024            | 10
TABLE
}

# --- 5. The developer's real cache dir was never touched --------------------
case_real_home_untouched() {
    local now=0; [ -e "$REAL_RUN_ALL" ] && now=1
    assert_eq "f2-cache/isolation/real-home-run-all-untouched" "$REAL_PRE" "$now"
}

case_preamble
case_bucket_formula
case_numeric_limits
case_bucket_transitions
case_real_home_untouched

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
