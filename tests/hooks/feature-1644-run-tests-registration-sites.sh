#!/usr/bin/env bash
# Tests: hooks/lib/sentinel-patterns.js, hooks/workflow-state/state-io/core.js, settings.json, hooks/workflow-gate.js, hooks/workflow-mark/not-needed-handlers.js, hooks/workflow-mark/mark-step-handler.js, docs/architecture/claude-code/workflow.md
# Tags: tl1, tl2, workflow, run-tests, docs-only, registration-sites, scope:issue-specific, pwsh-not-required
#
# #1644 stage 2 — exhaustive pin of the SIX registration sites the run_tests
# docs-only skip path must land on, plus two adjacent guarantees. One case per site: a
# single unregistered site fails exactly one named case, so the failure output
# says WHICH site is missing rather than "the feature does not work".
#
# The critical asymmetry is R6: MARK_STEP_* is unconditionally allowed by
# settings.json, so SKIPPABLE_STEPS gaining "run_tests" without the
# mark-step-handler guard opens an unapproved, docs-only-unverified skip.
# R6c pins the conjunction directly and is RED until the guard exists.
#
# TL3 gap (what this test does NOT catch):
# - Whether the real permission layer auto-approves the settings.json allow entry
#   (only the JSON membership is asserted, not a live dialog).
# - Whether a real session's workflow-gate invocation resolves the same repo dir
#   that these fixtures pin via CLAUDE_PROJECT_DIR.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh categories: hook-registration, skill-orchestration.

set -uo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

SUBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1644-run-tests-registration-sites"

# shellcheck source=./feature-1644-run-tests-registration-sites/helpers.sh
. "$SUBDIR/helpers.sh"
# shellcheck source=./feature-1644-run-tests-registration-sites/static-sites.sh
. "$SUBDIR/static-sites.sh"
# shellcheck source=./feature-1644-run-tests-registration-sites/runtime-sites.sh
. "$SUBDIR/runtime-sites.sh"

run_static_site_cases
run_runtime_site_cases

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
