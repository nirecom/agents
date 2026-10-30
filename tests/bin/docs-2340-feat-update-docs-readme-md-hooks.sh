#!/usr/bin/env bash
# tests/bin/docs-2340-feat-update-docs-readme-md-hooks.sh
# Tests: hooks/workflow-gate/review-docs-checker.js
# Tags: TL2, docs, review-docs, staged, git, scope:issue-specific, pwsh-not-required
# #2340 groups D (hooks/lib/staged-doc-changes.js) and E (review-docs-checker); split out of docs-2340-feat-update-docs-readme-md.sh (#2723).
# TL3 gap: no live claude -p hook dispatch; no Windows-native output parity.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
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

echo "=== GROUP D: hooks/lib/staged-doc-changes.js ==="
run_group_d
echo ""
echo "=== GROUP E: hooks/workflow-gate/review-docs-checker.js ==="
run_group_e

docs2340_finish
