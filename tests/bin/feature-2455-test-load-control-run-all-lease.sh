#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control-run-all-lease.sh
# Tests: tests/run-all.sh,bin/lib/test-host-lanes.sh
# Tags: TL2, scope:issue-specific, lanes, dup-group-keep:size-hard-limit
# Part of the #2455 suite (dispatcher: feature-2455-test-load-control.sh): R1-R7.
# TL3 gap (what this test does NOT catch):
# - real contention between several Claude sessions and a full-suite run on one host
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

case_begin "preconditions-run-all" "tests/run-all.sh"
p0_exists "tests/run-all.sh" "$RUN_ALL"
case_end

case_begin "preconditions-host-lanes" "bin/lib/test-host-lanes.sh"
p0_exists "bin/lib/test-host-lanes.sh" "$LANES_LIB"
case_end

# shellcheck source=feature-2455-test-load-control/_fixture.sh
. "$GROUP_DIR/_fixture.sh"
# shellcheck source=feature-2455-test-load-control/_runner-fixture.sh
. "$GROUP_DIR/_runner-fixture.sh"
# shellcheck source=feature-2455-test-load-control/run-all-lease-cases.sh
. "$GROUP_DIR/run-all-lease-cases.sh"

entry_finish "${BASH_SOURCE[0]}" "tests/run-all.sh" "R1 R2 R3 R4 R5 R6 R7"
