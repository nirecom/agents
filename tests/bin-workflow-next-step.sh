#!/usr/bin/env bash
# Tests: bin/workflow/next-step
# Tags: L2, workflow, wf-meta, scope:common
#
# L2 test of the workflow oracle's state-transition resolver and --list renderer.
# Source under test does NOT yet exist (TDD phase A — RED state expected).
#
# Dispatcher: shared helpers/fixtures live in bin-workflow-next-step/common.sh;
# case groups live in transitions.sh, list-render.sh, wf-meta-evidence.sh.
#
# L3 gap (what this test does NOT catch):
# - Real CLAUDE_SESSION_ID environment propagation from a live claude -p session
# - Actual workflow-mark.js sentinel dispatch triggering oracle consumption
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -euo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TMPDIR_WT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WT"' EXIT
export CLAUDE_WORKFLOW_DIR="$TMPDIR_WT"

# Derive oracle path from the test file's own location so worktree runs
# test the worktree's oracle rather than the one in $AGENTS_CONFIG_DIR.
ORACLE_AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin-workflow-next-step"

# shellcheck source=./bin-workflow-next-step/common.sh
. "$SCRIPT_DIR/common.sh"
# shellcheck source=./bin-workflow-next-step/transitions.sh
. "$SCRIPT_DIR/transitions.sh"
# shellcheck source=./bin-workflow-next-step/list-render.sh
. "$SCRIPT_DIR/list-render.sh"
# shellcheck source=./bin-workflow-next-step/wf-meta-evidence.sh
. "$SCRIPT_DIR/wf-meta-evidence.sh"

# run_with_timeout wraps each individual `node` invocation inside run_oracle
# (timeout/perl-exec cannot wrap shell functions directly, so per-call bounding
# is the portable shape — matches tests/feature-1027-state-schema-eligible-phase.sh).
run_transitions_tests
run_list_render_tests
run_wf_meta_evidence_tests

echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
