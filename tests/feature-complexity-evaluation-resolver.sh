#!/bin/bash
# Tests: hooks/workflow-state/skip-signal-resolver.js, hooks/workflow-state/state-io.js, bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation
# Tags: L2, workflow, complexity-evaluation, scope:issue-specific
#
# Issue #1350 — one-time persisted SSOT for the S1..S6 complexity evaluation.
#
# recordComplexityEvaluation(sessionId, verdict, signals) persists a single
# complexity verdict into workflow state (createInitialState seeds the slot);
# readComplexityEvaluation / hasComplexityEvaluation are read-only accessors on
# skip-signal-resolver.js and fail-open (missing/invalid → null / false).
#
# CLIs bin/workflow/{record,read}-complexity-evaluation wrap the write/read APIs
# for SKILL.md Bash calls.
#
# Pre-implementation model: the write/read APIs and CLIs may not yet exist. This
# suite does NOT exit 77 globally. Instead it probes API/CLI presence once, sets
# API_READY / CLI_READY, and SKIPs individual cases (incrementing SKIP, not FAIL)
# when the target is absent. Result: exit 0 (all SKIP) before implementation, and
# real FAILs after implementation lands but misbehaves. SKIP never counts as FAIL.
#
# L3 gap (what this test does NOT catch):
# - Real orchestrator-driven single-write flow across CI-C1b / MDP-3 / WCD-3 /
#   WT-5 in a live claude -p session (this test drives the APIs/CLIs directly
#   with synthetic session state, not a real workflow run).
# Closest-to-action mitigation: static reader-ordering checks in the sibling
# feature-clarify-intent-complexity-write-static.sh / feature-1350-mdp-wt-reader-static.sh
# and the write-code-skill-static reader assertions.

set -uo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

# Setup, presence probes, counters, and helpers live in the sibling lib
# (rules/coding/file-split.md Pattern A — entrypoint-private module).
# shellcheck source=tests/feature-complexity-evaluation-resolver/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-complexity-evaluation-resolver/lib.sh"

# Cases — sourced fragments (Pattern A split; rules/coding/file-split.md).
# They execute at source time, so this order IS the execution order.
# shellcheck source=tests/feature-complexity-evaluation-resolver/api-cases.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-complexity-evaluation-resolver/api-cases.sh"
# shellcheck source=tests/feature-complexity-evaluation-resolver/cli-cases.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-complexity-evaluation-resolver/cli-cases.sh"
# shellcheck source=tests/feature-complexity-evaluation-resolver/shim-cases.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-complexity-evaluation-resolver/shim-cases.sh"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
exit "$FAIL"
