#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control.sh
# Tests: bin/find-tests-for-source.sh,bin/lib/test-corpus-cache.sh,bin/lib/test-host-lanes.sh,bin/test-lanes-status.sh,tests/run-all.sh,bin/lib/run-all-parallelism.sh,bin/calibrate-test-parallelism.sh,install/settings-allow-commands.txt
# Tags: TL2, scope:issue-specific, find-tests, corpus-cache, lanes, fork-count
# Dispatcher for #2455 (+#2412): fork-free find-tests, corpus cache, host test lanes.
# TL3 gap (what this test does NOT catch):
# - real contention between several Claude sessions and a full-suite run on one host
# - Bash-tool timeout (600000) interplay with the exit-4 message in a live skill run
# Mitigation: WORKFLOW_USER_VERIFIED preflight on a host with a concurrent run-all.

set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$AGENTS_ROOT/tests/lib/harness.sh"
GROUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-2455-test-load-control"
HELPER="$AGENTS_ROOT/bin/find-tests-for-source.sh"
ROUTE_LIB="$AGENTS_ROOT/bin/lib/test-route-destination.sh"
CORPUS_LIB="$AGENTS_ROOT/bin/lib/test-corpus-cache.sh"
LANES_LIB="$AGENTS_ROOT/bin/lib/test-host-lanes.sh"
PAR_LIB="$AGENTS_ROOT/bin/lib/run-all-parallelism.sh"
STATUS_CLI="$AGENTS_ROOT/bin/test-lanes-status.sh"
RUN_ALL="$AGENTS_ROOT/tests/run-all.sh"
CALIBRATOR="$AGENTS_ROOT/bin/calibrate-test-parallelism.sh"
ALLOW_TXT="$AGENTS_ROOT/install/settings-allow-commands.txt"
RUN_TIMEOUT="$AGENTS_ROOT/bin/run-with-timeout.sh"

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $1"; }

# assert_eq <name> <want> <got>
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        pass "$name"
    else
        fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md).
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPDIR_BASE/transcripts"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR" "$CLAUDE_TRANSCRIPT_BASE_DIR"
unset CLAUDE_CODE_SESSION_ID
# Slots and the corpus cache must never reach the developer's ~/.claude/run-all, and
# an inherited lane control would silently change which path a case exercises.
export RUN_ALL_CACHE_DIR="$TMPDIR_BASE/run-all-cache"
unset TEST_LANES_HELD TEST_LANES FIND_TESTS_CORPUS_CACHE TEST_LANES_TTL TEST_LANES_HEARTBEAT \
    TEST_LANES_WAIT_INTERVAL TEST_LANES_WAIT_CAP TEST_LANES_BUDGET RUN_ALL_LANES_LIB \
    TCC_LOGIC_DIR RUN_ALL_EXPECT_BUCKET TESTS_DIR GIT_DIR GIT_WORK_TREE

NEUTRAL_DIR="$TMPDIR_BASE/neutral"
mkdir -p "$NEUTRAL_DIR"

# ── Completion ledger (GRP pattern, as in feature-2075-append-destination.sh) ─
GRP_DONE=""
grp_done() { GRP_DONE="${GRP_DONE}$1
"; }
CASE_RAN=""
case_ran() { CASE_RAN="${CASE_RAN} $1"; }

# p0_exists <rel> <abs> — precondition: the target file exists.
p0_exists() {
    if [[ -f "$2" ]]; then pass "P0 $1 exists"; else fail "P0 $1 missing (not implemented yet)"; fi
}

# ── Preconditions: one existence case per Tests-header path ─────────────────
case_begin "preconditions-find-tests" "bin/find-tests-for-source.sh"
p0_exists "bin/find-tests-for-source.sh" "$HELPER"
case_end

case_begin "preconditions-corpus-cache" "bin/lib/test-corpus-cache.sh"
p0_exists "bin/lib/test-corpus-cache.sh" "$CORPUS_LIB"
case_end

case_begin "preconditions-host-lanes" "bin/lib/test-host-lanes.sh"
p0_exists "bin/lib/test-host-lanes.sh" "$LANES_LIB"
case_end

case_begin "preconditions-lanes-status" "bin/test-lanes-status.sh"
p0_exists "bin/test-lanes-status.sh" "$STATUS_CLI"
case_end

case_begin "preconditions-run-all" "tests/run-all.sh"
p0_exists "tests/run-all.sh" "$RUN_ALL"
case_end

case_begin "preconditions-parallelism" "bin/lib/run-all-parallelism.sh"
p0_exists "bin/lib/run-all-parallelism.sh" "$PAR_LIB"
case_end

case_begin "preconditions-calibrator" "bin/calibrate-test-parallelism.sh"
p0_exists "bin/calibrate-test-parallelism.sh" "$CALIBRATOR"
case_end

case_begin "preconditions-allow-commands" "install/settings-allow-commands.txt"
p0_exists "install/settings-allow-commands.txt" "$ALLOW_TXT"
case_end

# ── Case files ──────────────────────────────────────────────────────────────
# shellcheck source=feature-2455-test-load-control/_fixture.sh
. "$GROUP_DIR/_fixture.sh"
# shellcheck source=feature-2455-test-load-control/fork-count-cases.sh
. "$GROUP_DIR/fork-count-cases.sh"
# shellcheck source=feature-2455-test-load-control/cache-cases.sh
. "$GROUP_DIR/cache-cases.sh"
# shellcheck source=feature-2455-test-load-control/lanes-cases.sh
. "$GROUP_DIR/lanes-cases.sh"
# shellcheck source=feature-2455-test-load-control/run-all-lease-cases.sh
. "$GROUP_DIR/run-all-lease-cases.sh"

case_begin "suite-integrity" "bin/find-tests-for-source.sh"

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
    fail "GRP1 case file set mismatch — present-but-unsourced: [${GRP_UNSOURCED:-none}] sourced-but-missing: [${GRP_ABSENT:-none}]"
fi
GRP_DONE_SORTED="$(printf '%s' "$GRP_DONE" | sort)"
GRP_UNFINISHED="$(grp_only_in_first "$GRP_SOURCED" "$GRP_DONE_SORTED")"
GRP_UNEXPECTED="$(grp_only_in_first "$GRP_DONE_SORTED" "$GRP_SOURCED")"
if [[ -z "$GRP_UNFINISHED" && -z "$GRP_UNEXPECTED" ]]; then
    pass "GRP2 every sourced case file ran through to its completion marker"
else
    fail "GRP2 case file completion mismatch — sourced-but-unfinished: [${GRP_UNFINISHED:-none}] marked-but-not-sourced: [${GRP_UNEXPECTED:-none}]"
fi

# CASE1 — every planned case id reported at least once.
CASE_EXPECTED="FC1 FC2 FC3 FC4 EQ1 C1 C2 C3 C4 C5 C6 C7 C8 C9 C10 C11 C12 C13 \
L1 L2 L3 L4 L5 L6 L7 L8 L9 L10 L11 L12 L13 L14 L15 L16 L17 L18 LS1 LS2 LS3 LS4 \
R1 R2 R3 R4 R5 R6 R7 R8 R9 R10 R11 R12"
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
    fail "CASE1 planned case ids that never ran: [$CASE_MISSING]"
fi

case_end

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
