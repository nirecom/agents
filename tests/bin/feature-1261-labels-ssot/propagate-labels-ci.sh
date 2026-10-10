#!/bin/bash
# tests/bin/feature-1261-labels-ssot/propagate-labels-ci.sh
# Tests: bin/github-issues/propagate-labels.sh
# Tags: labels-ssot, propagation, github-issues, scope:issue-specific
# L3 gap (what this test does NOT catch) — mock git/gh intercept every call:
# - Real GitHub API calls and PAT authentication (no HTTPS connection is made).
# - Branch-protection push rejection (mock git push always succeeds).
# - Real `git diff` computation (mock reads the GIT_DIFF_RC env knob).
# - Real sync-labels.sh against the live gh API (T-propagate-6 uses mock gh only).
# Mitigation: WORKFLOW_USER_VERIFIED preflight (category: skill-orchestration).

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# pass / fail / assert_eq / __LIB_SCRIPT_CHECKOUT_ROOT / run_with_timeout provided by _lib.sh.

# Allow overriding the script path so tests can validate against a throwaway
# reference implementation before the real bin path exists.
TARGET="${PROPAGATE_LABELS_SH:-$__LIB_SCRIPT_CHECKOUT_ROOT/bin/github-issues/propagate-labels.sh}"

GENERATED_HEADER="# GENERATED — source: nirecom/agents .github/labels.yml — do not edit directly"

TMP=""

# shellcheck source=propagate-labels-ci/_setup.sh
. "$(dirname "${BASH_SOURCE[0]}")/propagate-labels-ci/_setup.sh"

# shellcheck source=propagate-labels-ci/_tests-core.sh
. "$(dirname "${BASH_SOURCE[0]}")/propagate-labels-ci/_tests-core.sh"

# shellcheck source=propagate-labels-ci/_tests-ci-fallback.sh
. "$(dirname "${BASH_SOURCE[0]}")/propagate-labels-ci/_tests-ci-fallback.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
