#!/usr/bin/env bash
# tests/bin/bin-concern-ledger-finalize-loop.sh
# Tests: bin/concern-ledger, bin/run-codex-review-loop, bin/lib/concern-ledger/finalize.sh, bin/lib/codex-review-loop/ref-kind-input.sh
# Tags: concern-ledger, finalize, review-loop, cap, convergence, scope:common, pwsh-not-required
# TL2 entrypoint (#2723 split of bin-concern-ledger-finalize.sh): loop integration, then the cap and convergence groups
# that reuse loop-integration.sh's mk_loop_env / mk_reviewer / run_loop helpers, so the three stay together and in order.
# TL3 gap (skill-orchestration): a skill whose table lists exit 7 but whose prose still emits the completion sentinel
# passes cases 8/9. Mitigation: a manual /review-code-security run, plus case 6(e) at TL2.
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

# Re-assigned here (same value as _lib.sh) so check-plans-dir-isolation resolves the sources below to this file's pin.
SUITE_DIR="$AGENTS_ROOT/tests/bin/bin-concern-ledger-finalize"

case_begin "finalize-loop-integration" "bin/run-codex-review-loop"
# shellcheck source=./bin-concern-ledger-finalize/loop-integration.sh
. "$SUITE_DIR/loop-integration.sh"
case_end

case_begin "finalize-cap-outline-detail" "bin/lib/concern-ledger/finalize.sh"
# shellcheck source=./bin-concern-ledger-finalize/cap-outline-detail.sh
. "$SUITE_DIR/cap-outline-detail.sh"
case_end

case_begin "finalize-convergence-after-nonconverged" "bin/lib/concern-ledger/finalize.sh"
# shellcheck source=./bin-concern-ledger-finalize/convergence-after-nonconverged.sh
. "$SUITE_DIR/convergence-after-nonconverged.sh"
case_end

clf_finish
