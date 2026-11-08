#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control-corpus-cache-fail-soft.sh
# Tests: bin/lib/test-corpus-cache.sh,bin/find-tests-for-source.sh
# Tags: TL2, scope:issue-specific, find-tests, corpus-cache, dup-group-keep:size-hard-limit
# Part of the #2455 suite (dispatcher: feature-2455-test-load-control.sh): C6-C13.
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

case_begin "preconditions-corpus-cache" "bin/lib/test-corpus-cache.sh"
p0_exists "bin/lib/test-corpus-cache.sh" "$CORPUS_LIB"
case_end

case_begin "preconditions-find-tests" "bin/find-tests-for-source.sh"
p0_exists "bin/find-tests-for-source.sh" "$HELPER"
case_end

# shellcheck source=feature-2455-test-load-control/_fixture.sh
. "$GROUP_DIR/_fixture.sh"
# shellcheck source=feature-2455-test-load-control/_cache-fixture.sh
. "$GROUP_DIR/_cache-fixture.sh"
# shellcheck source=feature-2455-test-load-control/cache-fail-soft-cases.sh
. "$GROUP_DIR/cache-fail-soft-cases.sh"

entry_finish "${BASH_SOURCE[0]}" "bin/lib/test-corpus-cache.sh" "C6 C7 C8 C9 C10 C11 C12 C13"
