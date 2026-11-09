#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/_entry.sh — the preamble every
# tests/bin/feature-2455-test-load-control*.sh entry shares. The #2455 suite is split
# into several entries so run-all runs them in parallel; each entry pins the fixture
# roots at top level, then sources this file, its case files and calls entry_finish.
# Needs: AGENTS_ROOT, GROUP_DIR, TMPDIR_BASE (readonly) set by the entry.

: "${AGENTS_ROOT:?}" "${GROUP_DIR:?}" "${TMPDIR_BASE:?}"

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

# Slots and the corpus cache must never reach the developer's ~/.claude/run-all, and
# an inherited lane control would silently change which path a case exercises.
export RUN_ALL_CACHE_DIR="$TMPDIR_BASE/run-all-cache"
unset TEST_LANES_HELD TEST_LANES FIND_TESTS_CORPUS_CACHE TEST_LANES_TTL TEST_LANES_HEARTBEAT \
    TEST_LANES_WAIT_INTERVAL TEST_LANES_WAIT_CAP TEST_MAX_JOBS_PER_HOST TEST_MAX_JOBS_PER_RUN \
    RUN_ALL_LANES_LIB TCC_LOGIC_DIR TESTS_DIR GIT_DIR GIT_WORK_TREE AUTO_CONFIG_TEST_MAX_JOBS
# A nonexistent resolver skips the .env layer, so the developer's real .env never
# decides a limit; cases that test that layer pass their own stub per call.
NO_CONFIG_VAR_CMD="$TMPDIR_BASE/no-such-config-var-cmd"
export RUN_ALL_CONFIG_VAR_CMD="$NO_CONFIG_VAR_CMD"

# p0_exists <rel> <abs> — precondition: the target file exists.
p0_exists() {
    if [[ -f "$2" ]]; then pass "P0 $1 exists"; else fail "P0 $1 missing (not implemented yet)"; fi
}

NEUTRAL_DIR="$TMPDIR_BASE/neutral"
mkdir -p "$NEUTRAL_DIR"

# ── Completion ledger (GRP pattern, as in feature-2075-append-destination.sh) ─
GRP_DONE=""
grp_done() { GRP_DONE="${GRP_DONE}$1"$'\n'; }
CASE_RAN=""
case_ran() { CASE_RAN="${CASE_RAN} $1"; }

# grp_only_in_first <list-a> <list-b> — the lines of a missing from b, space-joined.
grp_only_in_first() {
    comm -23 <(printf '%s\n' "$1" | grep -v '^$' | sort) <(printf '%s\n' "$2" | grep -v '^$' | sort) \
        | tr '\n' ' ' | sed 's/ *$//'
}
# grp_sourced <entry-file>... — the group files those entries source, one per line.
grp_sourced() {
    sed -n 's|^\. "\$GROUP_DIR/\(.*\.sh\)"$|\1|p' "$@" | sort -u
}

# entry_finish <entry-file> <target> <case ids> — GRP2 (every file this entry sourced reached
# its completion marker) and CASE1 (every id planned for this entry ran), then the results.
entry_finish() {
    local entry="${1:?}" target="${2:?}" ids="${3:?}" sourced unfinished unexpected missing="" c
    case_begin "suite-integrity" "$target"
    sourced="$(grp_sourced "$entry")"
    unfinished="$(grp_only_in_first "$sourced" "$GRP_DONE")"
    unexpected="$(grp_only_in_first "$GRP_DONE" "$sourced")"
    if [[ -n "$sourced" && -z "$unfinished" && -z "$unexpected" ]]; then
        pass "GRP2 every sourced case file ran through to its completion marker"
    else
        fail "GRP2 case file completion mismatch — sourced-but-unfinished: [${unfinished:-none}] marked-but-not-sourced: [${unexpected:-none}]"
    fi
    for c in $ids; do
        case " $CASE_RAN " in
            *" $c "*) ;;
            *) missing="${missing:+$missing }$c" ;;
        esac
    done
    if [[ -z "$missing" ]]; then
        pass "CASE1 every planned case id ran"
    else
        fail "CASE1 planned case ids that never ran: [$missing]"
    fi
    case_end

    echo ""
    echo "─────────────────────────────────────────"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    [[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
}

grp_done _entry.sh
