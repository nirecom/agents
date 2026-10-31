#!/usr/bin/env bash
# tests/bin/docs-2340-feat-update-docs-readme-md.sh
# Tests: bin/review-doc-size, bin/review-doc-heading-order
# Tags: TL2, docs, review-docs, staged, git, scope:issue-specific, pwsh-not-required
# #2340 — README conciseness + .md line limits enforced at the review_docs step.
# Groups A and B; groups C+F and D+E run as -gates.sh and -hooks.sh (#2723 split), sharing docs-2340-feat-update-docs-readme-md/_lib.sh.
# TDD: every source under test is NEW/MODIFIED and unbuilt; cases fail LOUD (RED), never skip.
# TL3 gap: no live claude -p hook dispatch; no Windows-native output parity.
# Mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category hook-registration.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
SCRIPT_CHECKOUT_ROOT_N="$(nrm "$SCRIPT_CHECKOUT_ROOT")"

TMPDIR_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t 'docs2340')"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# fixture isolation (rules/test/fixture-isolation.md)
WORKFLOW_DIR="$TMPDIR_BASE/wf"
PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
export WORKFLOW_STATE_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
unset CLAUDE_CODE_SESSION_ID

CONFIG_EMPTY="$TMPDIR_BASE/cfg-empty"
mkdir -p "$CONFIG_EMPTY"
: > "$CONFIG_EMPTY/.env"
export AGENTS_MAIN_ROOT="$(nrm "$CONFIG_EMPTY")"

. "$SCRIPT_CHECKOUT_ROOT/tests/bin/docs-2340-feat-update-docs-readme-md/_lib.sh"

echo "=== GROUP A: bin/review-doc-size (staged/all, thresholds, exclusions) ==="
run_group_a
echo ""
echo "=== GROUP B: bin/review-doc-heading-order (SSOT, order, aliases) ==="
run_group_b

docs2340_finish
