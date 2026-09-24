#!/usr/bin/env bash
# Tests: hooks/workflow-state/plan-skip-allowance.js, hooks/lib/plan-confirm-flag.js, hooks/lib/load-env.js, hooks/workflow-state/record-step-verdict.js, bin/workflow/next-step, bin/workflow/lib/next-step/advance-shared.js, bin/workflow/lib/next-step/repo-dir.js
# Tags: tl2, workflow, security, skip-authorization, confirm-tests, config-dependent, classifier, scope:issue-specific, pwsh-not-required
#
# #1644 review gap C7 — skip AUTHORIZATION on the CLI door, end to end.
#
# The governing config key (established from source, not assumed): CONFIRM_TESTS.
#   hooks/workflow-state/plan-skip-allowance.js STAGE_FOR_STEP maps
#   write_tests -> "tests"; hooks/lib/plan-confirm-flag.js getConfirmFlagName
#   turns "tests" into CONFIRM_TESTS; record-step-verdict.js checkSkipAllowance
#   calls isSkipAllowedForCliPath("write_tests") before permitting the skip.
#   run_tests has NO config key at all — its authorization is the machine-checked
#   docs-only staged-set proof, so it is covered on its own axis (C7-6).
#
# The whole point of the CLI door is a TRUST BOUNDARY: it reads the config FILE
# and never process.env, because any process the Bash tool can spawn could be
# launched as `CONFIRM_TESTS=off node bin/...` and that prefix is model-issued
# text, never user approval. Same reasoning for CLAUDE_PROJECT_DIR on the
# run_tests door (record-step-verdict.js resolveTrustedRepoDirForRunTestsSkip).
#
# Dispatcher: fixtures/helpers in
# feature-1644-review-gap-c7-skip-authorization-security/helpers.sh; case groups
# in confirm-tests.sh (the CONFIRM_TESTS axis) and forged-inputs.sh (adversarial
# env / project-dir input).
#
# Sibling boundary (no duplication): tests/feature-1644-plan-skip-allowance-ssot.sh
# P3/P4/P5 exercise the MODULE predicate directly (isSkipAllowedForCliPath vs
# isSkipAllowedForSentinelPath). This file exercises the same boundary through
# the REAL CLI subprocess — the layer where a forged prefix would actually be
# typed — and adds the loader's value-normalization matrix plus the
# protected-resource negative assertions. feature-1644-run-tests-docs-only.sh
# D5/D5b cover the ALIGNED CLAUDE_PROJECT_DIR case; C7-6 covers the MISMATCHED
# (forged) one, which no existing case reaches.
#
# Protection-fix patterns applied (skills/_shared/test-design/protection-fix-tests.md):
#   Pattern 1 — every refusal asserts the protected resources are unchanged
#               (state file bytes + the fixture repo's status and file listing).
#   Pattern 2 — the forged-prefix cases reproduce the attack shape itself.
#   Pattern 4 — both verdicts of the classifier are covered on every axis.
#
# TL3 gap (what this test does NOT catch):
# - Whether a live Claude Code session's permission layer would even let the
#   model type an inline `CONFIRM_TESTS=off node ...` prefix into the Bash tool.
# - Whether the real agents .env on a developer machine resolves through the
#   same configDirCandidates order that AGENTS_CONFIG_DIR pins here.
# Closest-to-action mitigation: surfaced at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

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
