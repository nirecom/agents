#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-lanes-share.sh
# Tests: bin/lib/test-host-lanes-share.sh, bin/lib/test-host-lanes.sh, tests/run-all.sh
# Tags: TL2, scope:issue-specific, lanes, fair-share, run-all, slow-start, per-run-cap, rebalance-on-sample
# Serial: concurrent run-all fixtures and heartbeat timing must not compete with other tests
# Dispatcher for #2687 / #2506 stage 3: presence records, run-all per-run lane cap, per-entry-script rebalance.
# TL3 gap (what this test does NOT catch):
# - real Windows PowerShell load counters and real external load (3D games, builds) on this host
# - several real Claude sessions running full suites at once; the fixture runs only dummies
# Mitigation: WORKFLOW_USER_VERIFIED preflight with two concurrent run-all on this host.

set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$AGENTS_ROOT/tests/lib/harness.sh"
GROUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-2687-test-host-lanes-share"
PAR_LIB="$AGENTS_ROOT/bin/lib/run-all-parallelism.sh"
LANES_LIB="$AGENTS_ROOT/bin/lib/test-host-lanes.sh"
SHARE_LIB="$AGENTS_ROOT/bin/lib/test-host-lanes-share.sh"
RUN_ALL="$AGENTS_ROOT/tests/run-all.sh"
RUN_TIMEOUT="$AGENTS_ROOT/bin/run-with-timeout.sh"

# assert_eq <name> <want> <got> — the harness's fail() keeps the case record honest.
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        pass "$name"
    else
        fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

TMPDIR_BASE="$(mktemp -d)"
readonly TMPDIR_BASE
LIVE_SLEEP=""
trap '[ -n "$LIVE_SLEEP" ] && kill "$LIVE_SLEEP" 2>/dev/null; chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md).
export WORKFLOW_STATE_DIR="$TMPDIR_BASE/workflow"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPDIR_BASE/transcripts"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$CLAUDE_TRANSCRIPT_BASE_DIR"
unset CLAUDE_CODE_SESSION_ID
export RUN_ALL_CACHE_DIR="$TMPDIR_BASE/run-all-cache"
unset TEST_LANES_HELD TEST_LANES FIND_TESTS_CORPUS_CACHE TEST_LANES_TTL TEST_LANES_HEARTBEAT \
    TEST_LANES_WAIT_INTERVAL TEST_LANES_WAIT_CAP TEST_MAX_JOBS_PER_HOST TEST_MAX_JOBS_PER_RUN \
    RUN_ALL_LANES_LIB TCC_LOGIC_DIR TESTS_DIR GIT_DIR GIT_WORK_TREE AUTO_CONFIG_TEST_MAX_JOBS \
    TEST_LANES_LOAD_PROBE_CMD
# A nonexistent resolver skips the .env layer, so the developer's real .env never decides a limit.
NO_CONFIG_VAR_CMD="$TMPDIR_BASE/no-such-config-var-cmd"
export RUN_ALL_CONFIG_VAR_CMD="$NO_CONFIG_VAR_CMD"
NEUTRAL_DIR="$TMPDIR_BASE/neutral"
mkdir -p "$NEUTRAL_DIR"

# A live pid that owns the fake presence records of the run-all cases.
sleep 600 &
LIVE_SLEEP=$!

# ── Completion ledger (GRP pattern, as in feature-2455-test-load-control.sh) ─
GRP_DONE=""
grp_done() { GRP_DONE="${GRP_DONE}$1"$'\n'; }
CASE_RAN=""
case_ran() { CASE_RAN="${CASE_RAN} $1"; }

p0_exists() {
    if [[ -f "$2" ]]; then pass "P0 $1 exists"; else fail "P0 $1 missing (not implemented yet)"; fi
}

case_begin "preconditions-share-lib" "bin/lib/test-host-lanes-share.sh"
p0_exists "bin/lib/test-host-lanes-share.sh" "$SHARE_LIB"
case_end

case_begin "preconditions-lanes-lib" "bin/lib/test-host-lanes.sh"
p0_exists "bin/lib/test-host-lanes.sh" "$LANES_LIB"
case_end

case_begin "preconditions-run-all" "tests/run-all.sh"
p0_exists "tests/run-all.sh" "$RUN_ALL"
case_end

# ── Case files ──────────────────────────────────────────────────────────────
# shellcheck source=feature-2687-test-host-lanes-share/_fixture.sh
. "$GROUP_DIR/_fixture.sh"
# shellcheck source=feature-2687-test-host-lanes-share/share-cases.sh
. "$GROUP_DIR/share-cases.sh"
# shellcheck source=feature-2687-test-host-lanes-share/rebalance-cases.sh
. "$GROUP_DIR/rebalance-cases.sh"
# shellcheck source=feature-2687-test-host-lanes-share/run-all-cases.sh
. "$GROUP_DIR/run-all-cases.sh"
# shellcheck source=feature-2687-test-host-lanes-share/load-shrink-cases.sh
. "$GROUP_DIR/load-shrink-cases.sh"

case_begin "suite-integrity" "bin/lib/test-host-lanes-share.sh"

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

# CASE1 — every planned case id reported at least once (FS15 = the max-jobs-per-host-1 floor;
# FS17-FS20 = the #2692 start width, burst and width-line cases; FS21 = stale sample -> tick -> rebalance;
# FS22-FS23 = thl_sample_new and the run-all rebalance on a new sample while every job runs).
CASE_EXPECTED="FS1 FS2 FS3 FS4 FS5 FS6 FS7 FS8 FS9 FS10 FS11 FS12 FS13 FS14 FS15 FS16 FS17 FS18 FS19 FS20 FS21 FS22 FS23"
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
