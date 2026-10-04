#!/usr/bin/env bash
# tests/tests/feature-1832-run-all-parallel/h3-serial-comment-prefix.sh
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, frontmatter, TL2, scope:issue-specific
set -u

# WHY (#2500): `Serial:` is read in each file's own registry header.commentPrefix, by
# run-all's serial lane and by the calibrator's candidate filter alike. A fixture
# table adds slash-lang (*.slt, "//"); a line in the other language's prefix is a decoy.
# TL3 gap: a real non-bash language's launcher; the fixture language runs under bash.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUNNER="$AGENTS_DIR/tests/run-all.sh"
# shellcheck source=../../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"   # for the case markers; the reporters below replace its own

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

# Same ambient sanitization as h-serial-header-convention.sh (senv outermost).
senv() {
    env -u RUN_ALL_JOBS -u RUN_ALL_DEADLINE -u RUN_ALL_PROGRESS -u RUN_ALL_REAP \
        -u FEATURE_644_PHASE "$@"
}
unset RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE
run_with_timeout() { local s="$1"; shift; senv bash "$AGENTS_DIR/bin/run-with-timeout.sh" "$s" "$@"; }

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ra-serial-prefix-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# --- fixture isolation (rules/test/fixture-isolation.md) --------------------
export CLAUDE_WORKFLOW_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/workflow-plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_CODE_SESSION_ID
export RUN_ALL_CACHE_DIR="$TMPD/cache"
mkdir -p "$RUN_ALL_CACHE_DIR"

# shellcheck source=../../bin/test-language-registry/slash-header-fixture.sh
. "$AGENTS_DIR/tests/bin/test-language-registry/slash-header-fixture.sh"
CO="$TMPD/co"
slash_fx_checkout "$CO" "$AGENTS_DIR" bin/calibrate-test-parallelism.sh

# fx_test <path> <serial-line-or-empty> — a header block in the file's own prefix,
# plus the given Serial line (which may be in the other prefix: a decoy).
fx_test() {
    local p="$1" serial="$2" pfx="#"
    case "$p" in *.slt) pfx="//" ;; esac
    if [ -n "$serial" ]; then
        slash_write "$p" "$pfx Tests: tests/run-all.sh" "$pfx Tags: fixture, scope:issue-specific" "$serial" 'exit 0'
    else
        slash_write "$p" "$pfx Tests: tests/run-all.sh" "$pfx Tags: fixture, scope:issue-specific" 'exit 0'
    fi
}

# 1. run-all --print-plan: the serial lane follows the per-file prefix.
case_run_all_serial_lane() {
    local FX="$TMPD/fx-plan" out rc serial parallel n
    fx_test "$FX/bin/s1.slt" '// Serial: real slash header'
    fx_test "$FX/bin/s2.slt" '# Serial: decoy for slash-lang'
    fx_test "$FX/bin/b1.sh" '# Serial: real hash header'
    fx_test "$FX/bin/b2.sh" '// Serial: decoy for bash'
    rc=0
    out="$(run_with_timeout 60 env "TESTS_DIR=$FX" "RUN_ALL_CACHE_DIR=$RUN_ALL_CACHE_DIR" TEST_LANES=off \
        "RUN_ALL_REGISTRY_LIB=$CO/bin/lib/test-language-registry.sh" \
        bash "$RUNNER" --print-plan --all 2>"$TMPD/plan-err.txt")" || rc=$?
    assert_eq "h3-prefix/plan/exit-zero" "0" "$rc"
    n="$(printf '%s\n' "$out" | sed -n 's/^serial_count=\([0-9][0-9]*\)$/\1/p' | head -1)"
    assert_eq "h3-prefix/plan/serial-count-is-2" "2" "${n:-(absent)}"
    serial="$(printf '%s\n' "$out" | awk -F'\t' '$1 == "plan" && $3 == "serial" { n = split($4, a, /[\/\\]/); print a[n] }' \
        | LC_ALL=C sort | tr '\n' ' ')"
    parallel="$(printf '%s\n' "$out" | awk -F'\t' '$1 == "plan" && $3 == "parallel" { n = split($4, a, /[\/\\]/); print a[n] }' \
        | LC_ALL=C sort | tr '\n' ' ')"
    assert_eq "h3-prefix/plan/serial-set-is-own-prefix-headers" "b1.sh s1.slt " "$serial"
    assert_eq "h3-prefix/plan/decoys-stay-parallel" "b2.sh s2.slt " "$parallel"
}

# 2. calibrate --dry-run: Serial tests leave the candidate set. Counts are chosen
# asymmetric so every wrong reading gives a different sample size: per-file prefix keeps
# the 2 + 3 decoys (5); "always #" would keep 1 + 3 (4); "always //" 2 + 1 (3).
case_calibrate_candidates() {
    local FX="$TMPD/fx-cal" out rc sample
    fx_test "$FX/sa1.slt" '// Serial: real'
    fx_test "$FX/sb1.slt" '# Serial: decoy'
    fx_test "$FX/sb2.slt" '# Serial: decoy'
    fx_test "$FX/hc1.sh" '# Serial: real'
    fx_test "$FX/hd1.sh" '// Serial: decoy'
    fx_test "$FX/hd2.sh" '// Serial: decoy'
    fx_test "$FX/hd3.sh" '// Serial: decoy'
    rc=0
    out="$(run_with_timeout 60 env "TESTS_DIR=$FX" "RUN_ALL_CACHE_DIR=$RUN_ALL_CACHE_DIR" \
        bash "$CO/bin/calibrate-test-parallelism.sh" --dry-run --sample 99 --jobs-list 1 2>"$TMPD/cal-err.txt")" || rc=$?
    assert_eq "h3-prefix/calibrate/exit-zero" "0" "$rc"
    sample="$(printf '%s\n' "$out" | sed -n 's/^plan: widths=.* sample=\([0-9][0-9]*\)$/\1/p' | head -1)"
    assert_eq "h3-prefix/calibrate/candidates-exclude-own-prefix-serial-only" "5" "${sample:-(absent)}"
}

case_begin "serial-lane-comment-prefix" "tests/run-all.sh"
case_run_all_serial_lane
case_end
case_begin "calibrate-candidates-comment-prefix" "bin/calibrate-test-parallelism.sh"
case_calibrate_candidates
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
