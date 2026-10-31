#!/usr/bin/env bash
# tests/bin/feature-2687-test-host-load.sh
# Tests: bin/lib/test-host-load.sh, bin/lib/test-host-load-probe.sh
# Tags: TL2, scope:issue-specific, lanes, load-scale-in, external-load, reserved-cores
# Serial: sampler ticks age samples against wall-clock heartbeats; probe-timeout cases wait out a heartbeat-clamped probe timeout (2-5s) and stub probes sleep up to 8s
# Dispatcher for #2687 / #2506 stage 4: load sample, hysteresis, reader, computation, roots.
# TL3 gap (what this test does NOT catch):
# - real Windows PowerShell counters (Win32_PerfRawData_PerfOS_Processor) under real external load
# - real external load (3D games, builds) shrinking a real run-all; every snapshot here is a fixture
# Mitigation: WORKFLOW_USER_VERIFIED preflight on this host with an external CPU burner running.

set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$AGENTS_ROOT/tests/lib/harness.sh"
GROUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-2687-test-host-load"
PAR_LIB="$AGENTS_ROOT/bin/lib/run-all-parallelism.sh"
LANES_LIB="$AGENTS_ROOT/bin/lib/test-host-lanes.sh"
LOAD_LIB="$AGENTS_ROOT/bin/lib/test-host-load.sh"
PROBE_LIB="$AGENTS_ROOT/bin/lib/test-host-load-probe.sh"
SAMPLE_LIB="$AGENTS_ROOT/bin/lib/test-host-load-sample.sh"
ALLOC_LIB="$AGENTS_ROOT/bin/lib/test-host-alloc.sh"
RUN_TIMEOUT="$AGENTS_ROOT/bin/run-with-timeout.sh"

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        pass "$name"
    else
        fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got") rc=${RC:-} err=$(printf '%q' "${ERR:-}")"
    fi
}

TMPDIR_BASE="$(mktemp -d)"
readonly TMPDIR_BASE
LIVE_SLEEP=""
LIVE_SLEEP2=""
LIVE_SLEEP3=""
trap '[ -n "$LIVE_SLEEP" ] && kill "$LIVE_SLEEP" 2>/dev/null; [ -n "$LIVE_SLEEP2" ] && kill "$LIVE_SLEEP2" 2>/dev/null; [ -n "$LIVE_SLEEP3" ] && kill "$LIVE_SLEEP3" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md).
export WORKFLOW_STATE_DIR="$TMPDIR_BASE/workflow"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPDIR_BASE/transcripts"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$CLAUDE_TRANSCRIPT_BASE_DIR"
unset CLAUDE_CODE_SESSION_ID
unset TEST_LANES_HELD TEST_LANES TEST_LANES_TTL TEST_LANES_HEARTBEAT TEST_LANES_WAIT_INTERVAL \
    TEST_LANES_WAIT_CAP TEST_MAX_JOBS_PER_HOST TEST_MAX_JOBS_PER_RUN AUTO_CONFIG_TEST_MAX_JOBS \
    TEST_LANES_LOAD_PROBE_CMD RUN_ALL_LANES_LIB GIT_DIR GIT_WORK_TREE
# A nonexistent resolver skips the .env layer, so the developer's real .env never decides a limit.
export RUN_ALL_CONFIG_VAR_CMD="$TMPDIR_BASE/no-such-config-var-cmd"
NEUTRAL_DIR="$TMPDIR_BASE/neutral"
mkdir -p "$NEUTRAL_DIR"

# Live pids that own the fixture lanes and presence records; one that has exited.
sleep 600 &
LIVE_SLEEP=$!
sleep 600 &
LIVE_SLEEP2=$!
# LIVE_SLEEP3 owns only an other-env lane (LS13): it must never become a root.
sleep 600 &
LIVE_SLEEP3=$!
bash -c 'exit 0' &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null

GRP_DONE=""
grp_done() { GRP_DONE="${GRP_DONE}$1"$'\n'; }
CASE_RAN=""
case_ran() { CASE_RAN="${CASE_RAN} $1"; }

p0_exists() {
    if [[ -f "$2" ]]; then pass "P0 $1 exists"; else fail "P0 $1 missing (not implemented yet)"; fi
}

case_begin "preconditions-load-lib" "bin/lib/test-host-load.sh"
p0_exists "bin/lib/test-host-load.sh" "$LOAD_LIB"
case_end

case_begin "preconditions-probe-lib" "bin/lib/test-host-load-probe.sh"
p0_exists "bin/lib/test-host-load-probe.sh" "$PROBE_LIB"
case_end

# ── Case files ──────────────────────────────────────────────────────────────
# shellcheck source=feature-2687-test-host-load/_fixture.sh
. "$GROUP_DIR/_fixture.sh"
# shellcheck source=feature-2687-test-host-load/sampler-cases.sh
. "$GROUP_DIR/sampler-cases.sh"
# shellcheck source=feature-2687-test-host-load/compute-cases.sh
. "$GROUP_DIR/compute-cases.sh"
# shellcheck source=feature-2687-test-host-load/internal-cases.sh
. "$GROUP_DIR/internal-cases.sh"
# shellcheck source=feature-2687-test-host-load/probe-cases.sh
. "$GROUP_DIR/probe-cases.sh"
# shellcheck source=feature-2687-test-host-load/claim-cases.sh
. "$GROUP_DIR/claim-cases.sh"
# shellcheck source=feature-2687-test-host-load/claim-heartbeat-cases.sh
. "$GROUP_DIR/claim-heartbeat-cases.sh"
# shellcheck source=feature-2687-test-host-load/claim-reread-cases.sh
. "$GROUP_DIR/claim-reread-cases.sh"

case_begin "suite-integrity" "bin/lib/test-host-load.sh"

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

CASE_EXPECTED="LS1 LS2 LS3 LS4 LS5 LS6 LS7 LS8 LS9 LS10 LS11 LS12 LS13 LS14 LS15 LS16 LS17 SNAP1 SNAP2 IN1 IN2 IN3 IN4 IN5 PB1 PB2 PB3 PB4 PB5 PB6 PB7 PB8 PB9 PB10 PB11 PB12 CL1 CL2 CL3 CL4 CL5 CL6 CL7 CL8 CL9 CL10 CL11 CL12 CL13 CL14 CL15 CL16 CL17 CL18 CL19"
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
