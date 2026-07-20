#!/usr/bin/env bash
# tests/fix-propagate-labels-fixes.sh
# Tests: bin/github-issues/propagate-labels.sh
# Tags: scope:issue-specific, propagate-labels
#
# TL3 gap (what this test does NOT catch):
# - Real gh auth token retrieval from the credential store
# - Real git global core.hooksPath affecting actual subprocess commits
# - Real network calls to GitHub API for label propagation
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AGENTS_DIR

_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")/fix-propagate-labels-fixes"
# shellcheck source=fix-propagate-labels-fixes/_lib.sh
. "$_LIB_DIR/_lib.sh"
# shellcheck source=fix-propagate-labels-fixes/core.sh
. "$_LIB_DIR/core.sh"
# shellcheck source=fix-propagate-labels-fixes/security.sh
. "$_LIB_DIR/security.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
