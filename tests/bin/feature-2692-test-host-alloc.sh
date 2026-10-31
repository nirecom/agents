#!/usr/bin/env bash
# tests/bin/feature-2692-test-host-alloc.sh — #2692 sample schema 2, memory cap, allocation, unmeasurable samples, slow start.
# Tests: bin/lib/test-host-alloc.sh, bin/lib/test-host-load-sample.sh
# Tags: TL2, scope:issue-specific, lanes, load-scale-in
# Serial: sampler ticks age samples against wall-clock heartbeats (2s) and fresh presence records
# TL3 gap (what this test does NOT catch):
# - the first tick on a real Windows host with a cold WMI; real macOS vm values and ps comm
# - the real constrainedMemory inside a Linux cgroup, and a real burst start after an OS restart
# Mitigation: before WORKFLOW_USER_VERIFIED start 3 run-alls at once on this host and read the
# load and presence rows of bash bin/test-lanes-status.sh every 2 minutes (widths grow from 4,
# the sum stays within pool, external load with no tests stays within reserved cores).

set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$AGENTS_ROOT/tests/lib/harness.sh"
GROUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-2692-test-host-alloc"
PAR_LIB="$AGENTS_ROOT/bin/lib/run-all-parallelism.sh"
LANES_LIB="$AGENTS_ROOT/bin/lib/test-host-lanes.sh"
ALLOC_LIB="$AGENTS_ROOT/bin/lib/test-host-alloc.sh"
SAMPLE_LIB="$AGENTS_ROOT/bin/lib/test-host-load-sample.sh"
RUN_TIMEOUT="$AGENTS_ROOT/bin/run-with-timeout.sh"
# shellcheck source=../lib/load-sample2-fixture.sh
source "$AGENTS_ROOT/tests/lib/load-sample2-fixture.sh"

# expect_eq <label> <want> <got> — the driver's RC and stderr ride along on a mismatch.
expect_eq() {
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3") rc=${RC:-} err=$(printf '%q' "${ERR:-}")"
    fi
}

TMPDIR_BASE="$(mktemp -d)"
readonly TMPDIR_BASE
LIVE_SLEEP=""
trap '[ -n "$LIVE_SLEEP" ] && kill "$LIVE_SLEEP" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md).
export WORKFLOW_STATE_DIR="$TMPDIR_BASE/workflow"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPDIR_BASE/transcripts"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$CLAUDE_TRANSCRIPT_BASE_DIR"
unset CLAUDE_CODE_SESSION_ID
unset TEST_LANES_HELD TEST_LANES TEST_LANES_TTL TEST_LANES_HEARTBEAT TEST_LANES_WAIT_INTERVAL \
    TEST_LANES_WAIT_CAP TEST_MAX_JOBS_PER_HOST TEST_MAX_JOBS_PER_RUN AUTO_CONFIG_TEST_MAX_JOBS \
    TEST_LANES_LOAD_PROBE_CMD RUN_ALL_LANES_LIB GIT_DIR GIT_WORK_TREE
export RUN_ALL_CACHE_DIR="$TMPDIR_BASE/default-cache"
# A nonexistent resolver skips the .env layer, so the developer's real .env never decides a limit.
export RUN_ALL_CONFIG_VAR_CMD="$TMPDIR_BASE/no-such-config-var-cmd"
NEUTRAL_DIR="$TMPDIR_BASE/neutral"
mkdir -p "$NEUTRAL_DIR"

# A live pid that owns every fixture lane and presence record.
sleep 600 &
LIVE_SLEEP=$!

GRP_DONE=""
grp_done() { GRP_DONE="${GRP_DONE}$1"$'\n'; }
CASE_RAN=""
case_ran() { CASE_RAN="${CASE_RAN} $1"; }

p0_exists() {
    if [[ -f "$2" ]]; then pass "P0 $1 exists"; else fail "P0 $1 missing (not implemented yet)"; fi
}

case_begin "preconditions-alloc-lib" "bin/lib/test-host-alloc.sh"
p0_exists "bin/lib/test-host-alloc.sh" "$ALLOC_LIB"
case_end

case_begin "preconditions-sample-lib" "bin/lib/test-host-load-sample.sh"
p0_exists "bin/lib/test-host-load-sample.sh" "$SAMPLE_LIB"
case_end

# ── Case files ──────────────────────────────────────────────────────────────
# shellcheck source=feature-2692-test-host-alloc/_fixture.sh
. "$GROUP_DIR/_fixture.sh"
# shellcheck source=feature-2692-test-host-alloc/sample-cases.sh
. "$GROUP_DIR/sample-cases.sh"
# shellcheck source=feature-2692-test-host-alloc/memory-cases.sh
. "$GROUP_DIR/memory-cases.sh"
# shellcheck source=feature-2692-test-host-alloc/alloc-cases.sh
. "$GROUP_DIR/alloc-cases.sh"
# shellcheck source=feature-2692-test-host-alloc/unmeasured-cases.sh
. "$GROUP_DIR/unmeasured-cases.sh"
# shellcheck source=feature-2692-test-host-alloc/slow-start-cases.sh
. "$GROUP_DIR/slow-start-cases.sh"
# shellcheck source=feature-2692-test-host-alloc/stale-cases.sh
. "$GROUP_DIR/stale-cases.sh"
# shellcheck source=feature-2692-test-host-alloc/cap-drop-cases.sh
. "$GROUP_DIR/cap-drop-cases.sh"

case_begin "suite-integrity" "bin/lib/test-host-alloc.sh"

GRP_PRESENT="$(ls -1 "$GROUP_DIR" 2>/dev/null | grep '\.sh$' | sort)"
GRP_SOURCED="$(sed -n 's|^\. "\$GROUP_DIR/\(.*\.sh\)"$|\1|p' "${BASH_SOURCE[0]}" | sort)"
grp_only_in_first() {
    comm -23 <(printf '%s\n' "$1" | grep -v '^$') <(printf '%s\n' "$2" | grep -v '^$') \
        | tr '\n' ' ' | sed 's/ *$//'
}
GRP_UNSOURCED="$(grp_only_in_first "$GRP_PRESENT" "$GRP_SOURCED")"
GRP_ABSENT="$(grp_only_in_first "$GRP_SOURCED" "$GRP_PRESENT")"
if [[ -z "$GRP_UNSOURCED" && -z "$GRP_ABSENT" ]]; then
    pass "GRP1 every case file is sourced and every sourced case file exists"
else
    fail "GRP1 case file set mismatch" "present-but-unsourced: [${GRP_UNSOURCED:-none}] sourced-but-missing: [${GRP_ABSENT:-none}]"
fi
GRP_DONE_SORTED="$(printf '%s' "$GRP_DONE" | sort)"
GRP_UNFINISHED="$(grp_only_in_first "$GRP_SOURCED" "$GRP_DONE_SORTED")"
GRP_UNEXPECTED="$(grp_only_in_first "$GRP_DONE_SORTED" "$GRP_SOURCED")"
if [[ -z "$GRP_UNFINISHED" && -z "$GRP_UNEXPECTED" ]]; then
    pass "GRP2 every sourced case file ran through to its completion marker"
else
    fail "GRP2 case file completion mismatch" "sourced-but-unfinished: [${GRP_UNFINISHED:-none}] marked-but-not-sourced: [${GRP_UNEXPECTED:-none}]"
fi

CASE_EXPECTED="SR1 SR2 SR3 SR4 SR5 SR6 MC1 MC2 MC3 MC4 MC5 MC6 MC7 MC8 MC9 MC10 MC11 MC12 AL1 AL2 AL3 AL4 AL5 AL6 AL7 UM1 UM2 UM3 UM4 UM5 UM6 UM7 SS1 SS2 SS3 SS4 SS5 SS6 SS7 SS8 SS9 SS10 SS11 ST1 ST2 ST3 ST4 CD1 CD2 CD3 CD4 CD5"
CASE_MISSING=""
for _c in $CASE_EXPECTED; do
    case " $CASE_RAN " in
        *" $_c "*) ;;
        *) CASE_MISSING="${CASE_MISSING:+$CASE_MISSING }$_c" ;;
    esac
done
if [[ -z "$CASE_MISSING" ]]; then
    pass "CASE1 every planned case id ran"
else
    fail "CASE1 planned case ids that never ran" "[$CASE_MISSING]"
fi

case_end

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
