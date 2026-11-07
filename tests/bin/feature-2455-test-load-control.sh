#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control.sh
# Tests: bin/find-tests-for-source.sh,bin/lib/test-corpus-cache.sh,bin/lib/test-host-lanes.sh,bin/test-lanes-status.sh,tests/run-all.sh,bin/lib/run-all-parallelism.sh,bin/calibrate-test-parallelism.sh,install/settings-allow-commands.txt
# Tags: TL2, scope:issue-specific, find-tests, corpus-cache, lanes, fork-count
# Dispatcher for #2455 (+#2412): preconditions, fork count, the registry fail-closed path,
# and the integrity of the split suite (the other parts run as feature-2455-test-load-control-*.sh).
# TL3 gap (what this test does NOT catch):
# - real contention between several Claude sessions and a full-suite run on one host
# - Bash-tool timeout (600000) interplay with the exit-4 message in a live skill run
# Mitigation: WORKFLOW_USER_VERIFIED preflight on a host with a concurrent run-all.

# No -e: cases capture a non-zero exit status on purpose (`cmd; _rc=$?`).
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$AGENTS_ROOT/tests/lib/harness.sh"
GROUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-2455-test-load-control"

TMPDIR_BASE="$(mktemp -d)"
readonly TMPDIR_BASE
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md).
export WORKFLOW_STATE_DIR="$TMPDIR_BASE/workflow"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPDIR_BASE/transcripts"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$CLAUDE_TRANSCRIPT_BASE_DIR"
unset CLAUDE_CODE_SESSION_ID

# shellcheck source=feature-2455-test-load-control/_entry.sh
. "$GROUP_DIR/_entry.sh"

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
# shellcheck source=feature-2455-test-load-control/registry-fail-closed-cases.sh
. "$GROUP_DIR/registry-fail-closed-cases.sh"

# ── The split suite as a whole ──────────────────────────────────────────────
case_begin "suite-split" "bin/find-tests-for-source.sh"
SPLIT_ENTRIES=("$AGENTS_ROOT"/tests/bin/feature-2455-test-load-control*.sh)
# GRP1 — every group file is sourced by some entry and every sourced file exists.
GRP_PRESENT="$(ls -1 "$GROUP_DIR" 2>/dev/null | grep '\.sh$')"
GRP_SOURCED="$(grp_sourced "${SPLIT_ENTRIES[@]}")"
GRP_UNSOURCED="$(grp_only_in_first "$GRP_PRESENT" "$GRP_SOURCED")"
GRP_ABSENT="$(grp_only_in_first "$GRP_SOURCED" "$GRP_PRESENT")"
if [[ -z "$GRP_UNSOURCED" && -z "$GRP_ABSENT" ]]; then
    pass "GRP1 every case file is sourced and every sourced case file exists"
else
    fail "GRP1 case file set mismatch — present-but-unsourced: [${GRP_UNSOURCED:-none}] sourced-but-missing: [${GRP_ABSENT:-none}]"
fi
# PLAN1 — the entries' CASE1 lists together still cover every planned case id.
CASE_PLANNED="FC1 FC2 FC3 FC4 EQ1 C1 C2 C3 C3b C4 C5 C6 C7 C8 C9 C10 C11 C12 C13 \
L1 L2 L3 L4 L5 L6 L7 L8 L9 L10 L11 L12 L13 L14 L15 L16 L17 L18 LS1 LS2 LS3 LS4 LS5 \
R1 R2 R3 R4 R5 R6 R7 R8 R9 R10 R11 R12 R13 CPU1 CPU2 CPU3 CPU5 CPU7 AC1 AC2 AC3 AC7 AC8 RF1 RF2"
CASE_CLAIMED=" $(sed -n 's/^entry_finish "[^"]*" "[^"]*" "\(.*\)"$/\1/p' "${SPLIT_ENTRIES[@]}" | tr '\n' ' ') "
PLAN_MISSING=""
for _c in $CASE_PLANNED; do
    case "$CASE_CLAIMED" in
        *" $_c "*) ;;
        *) PLAN_MISSING="${PLAN_MISSING:+$PLAN_MISSING }$_c" ;;
    esac
done
if [[ -z "$PLAN_MISSING" ]]; then
    pass "PLAN1 every planned case id is checked by one of the ${#SPLIT_ENTRIES[@]} entries"
else
    fail "PLAN1 planned case ids no entry checks: [$PLAN_MISSING]"
fi
case_end

entry_finish "${BASH_SOURCE[0]}" "bin/find-tests-for-source.sh" "FC1 FC2 FC3 FC4 RF1 RF2"
