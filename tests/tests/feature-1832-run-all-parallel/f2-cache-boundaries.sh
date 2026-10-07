#!/usr/bin/env bash
# tests/tests/feature-1832-run-all-parallel/f2-cache-boundaries.sh
# Tests: tests/run-all.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, cache, boundary, off-by-one, TL2, scope:issue-specific, lanes-status
# Serial: timing-sensitive parallelism measurements must not compete with other tests
# WHY (CPR-WPH): f-cache.sh proves each rejection class exists but can't see an off-by-one, so
# every limit is asserted from BOTH sides. #2079: read through line 1 of bin/test-lanes-status.sh
# (the runner no longer reads the record); the bucket cases left with the bucket itself.
# ISOLATION: temp RUN_ALL_CACHE_DIR, absent RUN_ALL_CONFIG_VAR_CMD, both max-jobs vars unset.
# TL3 gap: a host genuinely owning 1024 job slots is not exercised here.

set -u

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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
export WORKFLOW_STATE_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/workflow-plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_CODE_SESSION_ID
unset TEST_MAX_JOBS_PER_RUN TEST_MAX_JOBS_PER_HOST TEST_LANES TEST_LANES_HELD
export RUN_ALL_CACHE_DIR="$TMPD/cache"
mkdir -p "$RUN_ALL_CACHE_DIR"
CACHE_FILE="$RUN_ALL_CACHE_DIR/parallelism.conf"
NO_CFG="$TMPD/absent-get-config-var"

REAL_RUN_ALL="${HOME:-/nonexistent}/.claude/run-all"
REAL_PRE=0; [ -e "$REAL_RUN_ALL" ] && REAL_PRE=1

MEASURED_AT="2026-01-02T03:04:05Z"

lib_eval() {
    [ -f "$LIB" ] || { printf '(lib-missing)'; return 0; }
    run_with_timeout 30 bash -c \
        'set -u; . "$0" >/dev/null 2>&1 || { printf "(lib-source-failed)"; exit 0; }; eval "$1"' \
        "$LIB" "$1" 2>/dev/null
}

S_OUT=""; S_RC=0; S_LINE=""
# status_run — the read-only status tool; S_LINE is the line that reports the record.
status_run() {
    S_RC=0
    S_OUT="$(run_with_timeout 30 env "RUN_ALL_CACHE_DIR=$RUN_ALL_CACHE_DIR" \
        "RUN_ALL_CONFIG_VAR_CMD=$NO_CFG" bash "$STATUS" 2>/dev/null)" || S_RC=$?
    S_LINE="$(printf '%s\n' "$S_OUT" | head -n 1)"
}

# gen_rec <max> <os> — exactly the 7 v2 keys, so only the field under test can reject it.
gen_rec() {
    printf 'schema=%s\nhost_id=%s\nos=%s\nmax_jobs_per_host=%s\nmeasured_at=%s\nsample_size=24\nrepeat=3\n' \
        "$SCHEMA" "$HOST_ID" "$2" "$1" "$MEASURED_AT"
}

# assert_line <name> <want> — `@ok:<n>` means `source=measured` at width n (an OS-version
# advice suffix is allowed); anything else is the reason token of a default-4 rejection.
assert_line() {
    local name="$1" want="$2"
    case "$want" in
        @ok:*)
            case "$S_LINE" in
                "max_jobs_per_host=${want#@ok:} source=measured"|"max_jobs_per_host=${want#@ok:} source=measured measured_on="*)
                    pass "$name" ;;
                *) fail "$name" "want 'max_jobs_per_host=${want#@ok:} source=measured', got=$(printf '%q' "$S_LINE")" ;;
            esac ;;
        *) assert_eq "$name" "max_jobs_per_host=4 source=default record=$want" "$S_LINE" ;;
    esac
}

SCHEMA=""; HOST_ID=""; OS_ATTR=""

# ===========================================================================
# 1. The default and schema constants themselves — asserted, not assumed
# ===========================================================================
case_preamble() {
    if lib_missing "f2-cache/preamble/default-per-host-is-4"; then
        fail "f2-cache/preamble/schema-is-2" "implementation missing: $LIB_REL"
        return
    fi
    assert_eq "f2-cache/preamble/default-per-host-is-4" "4" \
        "$(lib_eval 'printf "%s" "${RUN_ALL_DEFAULT_MAX_JOBS_PER_HOST:-(unset)}"')"
    SCHEMA="$(lib_eval 'printf "%s" "${RUN_ALL_CACHE_SCHEMA:-(unset)}"')"
    assert_eq "f2-cache/preamble/schema-is-2" "2" "$SCHEMA"
    HOST_ID="$(lib_eval 'run_all_host_id')"
    OS_ATTR="$(lib_eval 'run_all_os_attr')"
    case "$OS_ATTR" in
        ?*/?*) pass "f2-cache/preamble/os-attr-available" ;;
        *) fail "f2-cache/preamble/os-attr-available" "run_all_os_attr gave $(printf '%q' "$OS_ATTR")" ;;
    esac
}

# ===========================================================================
# 2. Numeric limits, both sides of every edge, through the status entry point.
#    padlines are `#` lines (skipped by the parser); linelen excludes the newline.
# ===========================================================================
case_numeric_limits() {
    local name mx padlines linelen want i pad
    while IFS='|' read -r name mx padlines linelen want; do
        name="$(trim "$name")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        mx="$(trim "$mx")"; padlines="$(trim "$padlines")"
        linelen="$(trim "$linelen")"; want="$(trim "$want")"
        if lib_missing "f2-cache/limit/$name"; then continue; fi

        gen_rec "$mx" "$OS_ATTR" > "$CACHE_FILE"
        i=1
        while [ "$i" -le "$padlines" ]; do printf '# pad %s\n' "$i" >> "$CACHE_FILE"; i=$((i + 1)); done
        if [ "$linelen" -gt 0 ]; then
            pad="$(printf 'x%.0s' $(seq 1 $((linelen - 1))))"
            printf '#%s\n' "$pad" >> "$CACHE_FILE"
        fi
        status_run
        assert_line "f2-cache/limit/$name" "$want"
        assert_eq "f2-cache/limit/$name/exit-zero" "0" "$S_RC"
    done <<'TABLE'
# name          | max  | padlines | linelen | want
max-0           | 0    | 0        | 0       | bad-max-jobs-per-host
max-1           | 1    | 0        | 0       | @ok:1
max-1024        | 1024 | 0        | 0       | @ok:1024
max-1025        | 1025 | 0        | 0       | bad-max-jobs-per-host
lines-64        | 6    | 57       | 0       | @ok:6
lines-65        | 6    | 58       | 0       | malformed
line-length-512 | 6    | 0        | 512     | @ok:6
line-length-513 | 6    | 0        | 513     | malformed
TABLE
}

# ===========================================================================
# 3. `os` version length: 64 characters is the last accepted, 65 the first rejected.
# ===========================================================================
case_os_version_length() {
    local fam v64 v65
    if lib_missing "f2-cache/os/version-64-accepted"; then
        fail "f2-cache/os/version-65-rejected" "implementation missing: $LIB_REL"
        return
    fi
    fam="${OS_ATTR%%/*}"; [ -n "$fam" ] || fam="Windows"
    v64="$(printf 'v%.0s' $(seq 1 64))"; v65="${v64}v"
    gen_rec 6 "$fam/$v64" > "$CACHE_FILE"; status_run
    assert_line "f2-cache/os/version-64-accepted" "@ok:6"
    gen_rec 6 "$fam/$v65" > "$CACHE_FILE"; status_run
    assert_line "f2-cache/os/version-65-rejected" "bad-os"
}

# --- 4. The developer's real cache dir was never touched --------------------
case_real_home_untouched() {
    local now=0; [ -e "$REAL_RUN_ALL" ] && now=1
    assert_eq "f2-cache/isolation/real-home-run-all-untouched" "$REAL_PRE" "$now"
}

case_preamble
case_numeric_limits
case_os_version_length
case_real_home_untouched

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
