#!/usr/bin/env bash
# tests/bin/bin-concern-ledger-finalize.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/finalize.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/render.sh, bin/run-codex-review-loop, bin/lib/codex-review-loop/ref-kind-input.sh
# Tags: concern-ledger, finalize, fail-closed, atomic-write, json-artifact, table-driven, scope:common, pwsh-not-required
# TL2 entrypoint for the non-convergence artifact and its fail-CLOSED termination path (#1992 / #1996).
# Runs the modes/schema and static-contract groups of tests/bin/bin-concern-ledger-finalize/; the other groups run as
# bin-concern-ledger-finalize-{atomic-failclosed,loop,corrupted-json}.sh (#2723 split). Shared helpers: _lib.sh.
# TL3 gap (skill-orchestration): a skill whose table lists exit 7 but whose prose
# still emits the completion sentinel passes cases 8/9; a real out-of-space
# filesystem and real finalize concurrency are unreached too. Mitigation: a
# manual /review-code-security run, plus case 6(e) at TL2.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

# Known-gap assertions (case 9c). Sourced after FAIL exists, which the helpers
# increment on an XPASS. See tests/lib/xfail.sh for the contract.
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

case_begin "finalize-modes-schema" "bin/lib/concern-ledger/finalize.sh"
# shellcheck source=./bin-concern-ledger-finalize/modes-schema.sh
. "$SUITE_DIR/modes-schema.sh"
case_end

case_begin "finalize-static-contracts" "bin/concern-ledger"
# shellcheck source=./bin-concern-ledger-finalize/static-contracts.sh
. "$SUITE_DIR/static-contracts.sh"
case_end

clf_finish
