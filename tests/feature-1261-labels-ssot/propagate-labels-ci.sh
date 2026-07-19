#!/bin/bash
# tests/feature-1261-labels-ssot/propagate-labels-ci.sh
# Tests: bin/github-issues/propagate-labels.sh
# Tags: labels-ssot, propagation, github-issues, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
# - Real GitHub API calls and PAT authentication not covered — mock git/gh
#   intercepts all network calls; no actual HTTPS connection is made.
# - Branch-protection push rejection not simulated — mock git push always
#   succeeds; a real protected branch would reject the push.
# - Real `git diff` computation not exercised — mock reads GIT_DIFF_RC env
#   knob; actual byte-level diff of labels.yml is not evaluated.
# - Real sync-labels.sh against live gh API not covered by most cases —
#   T-propagate-6 exercises the real sync-labels.sh against mock gh only.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# pass / fail / assert_eq / AGENTS_DIR / run_with_timeout provided by _lib.sh.

# Allow overriding the script path so tests can validate against a throwaway
# reference implementation before the real bin path exists.
TARGET="${PROPAGATE_LABELS_SH:-$AGENTS_DIR/bin/github-issues/propagate-labels.sh}"

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
