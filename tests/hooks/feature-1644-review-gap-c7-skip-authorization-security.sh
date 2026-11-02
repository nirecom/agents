#!/usr/bin/env bash
# Tests: hooks/workflow-state/plan-skip-allowance.js, hooks/lib/plan-confirm-flag.js, hooks/lib/load-env.js, hooks/workflow-state/record-step-verdict.js, bin/workflow/next-step, bin/workflow/lib/next-step/advance-shared.js, bin/workflow/lib/next-step/repo-dir.js
# Tags: tl2, workflow, security, skip-authorization, confirm-tests, config-dependent, classifier, scope:issue-specific, pwsh-not-required
# #1644 C7: the CLI skip door reads CONFIRM_TESTS (CONFIRM_FLAG_OF_STEP) from the config FILE, never a forged env prefix.
# Cases: confirm-tests.sh, forged-inputs.sh; module-level siblings: feature-1644-plan-skip-allowance-ssot.sh.
# TL3 gap (what this test does NOT catch):
# - Whether the live permission layer lets the model type an inline `CONFIRM_TESTS=off node ...` prefix.
# - Whether the real agents .env resolves through the order AGENTS_MAIN_ROOT pins here.
# Closest-to-action mitigation: bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

SUBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1644-review-gap-c7-skip-authorization-security"

# shellcheck source=./feature-1644-review-gap-c7-skip-authorization-security/helpers.sh
. "$SUBDIR/helpers.sh"
# shellcheck source=./feature-1644-review-gap-c7-skip-authorization-security/confirm-tests.sh
. "$SUBDIR/confirm-tests.sh"
# shellcheck source=./feature-1644-review-gap-c7-skip-authorization-security/forged-inputs.sh
. "$SUBDIR/forged-inputs.sh"

run_confirm_cases
run_forged_cases

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
