#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing-traversal.sh
# Tests: hooks/workflow-state/complexity-routing.js, hooks/workflow-state.js, bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation, bin/workflow/derive-complexity-level
# Tags: complexity, routing, stage, cli, security, traversal, scope:issue-specific
# Issue #2099 (#2723 split) — paths-as-input axis: traversal, charset and signals-file cases.
# Fixtures + helpers: feature-2099-complexity-stage-routing/_lib.sh.
set -uo pipefail

. "$(cd "$(dirname "$0")/../.." && pwd)/tests/lib/harness.sh"
# Pinned here at top level, before anything runs (rules/test/fixture-isolation.md).
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export WORKFLOW_STATE_DIR="$WORKFLOW_DIR"
WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
export WORKFLOW_PLANS_DIR
export AGENTS_STATE_DIR="$TMPDIR_BASE/agents-state"
mkdir -p "$AGENTS_STATE_DIR"
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The skills' documented commands spell their CLI through this root: pin it to the checkout under test.
export AGENTS_MAIN_ROOT="$SCRIPT_CHECKOUT_ROOT"
. "$(dirname "$0")/feature-2099-complexity-stage-routing/_lib.sh"
CASE_DIR="$(dirname "$0")/feature-2099-complexity-stage-routing"

case_begin "dispatch-case-files-traversal" "bin/workflow/record-complexity-evaluation"
. "$CASE_DIR/traversal-attack-cases.sh"
# Both reuse the traversal snapshot (d2099t_snapshot) and canary-tree convention.
. "$CASE_DIR/path-charset-cases.sh"
. "$CASE_DIR/signals-file-security-cases.sh"
case_end

d2099_finish
