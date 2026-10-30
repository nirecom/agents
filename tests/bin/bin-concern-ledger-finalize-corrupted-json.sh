#!/usr/bin/env bash
# tests/bin/bin-concern-ledger-finalize-corrupted-json.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger/finalize.sh
# Tags: concern-ledger, finalize, json-artifact, corruption, scope:common, pwsh-not-required
# TL2 entrypoint (#2723 split of bin-concern-ledger-finalize.sh): the corrupted-JSON group.
# TL3 gap (skill-orchestration): a real out-of-space filesystem and real finalize concurrency are unreached.
# Mitigation: a manual /review-code-security run, plus case 6(e) at TL2.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

. "$AGENTS_ROOT/tests/lib/xfail.sh"
. "$AGENTS_ROOT/tests/lib/harness.sh"

# Fixture isolation (rules/test/fixture-isolation.md).
TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export WORKFLOW_STATE_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR"
cd "$TMPDIR_BASE" || exit 1

# shellcheck source=./bin-concern-ledger-finalize/_lib.sh
. "$AGENTS_ROOT/tests/bin/bin-concern-ledger-finalize/_lib.sh"

case_begin "finalize-corrupted-json" "bin/lib/concern-ledger/finalize.sh"
# shellcheck source=./bin-concern-ledger-finalize/corrupted-json.sh
. "$SUITE_DIR/corrupted-json.sh"
case_end

clf_finish
