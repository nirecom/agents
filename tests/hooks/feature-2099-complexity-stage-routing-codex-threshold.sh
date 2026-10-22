#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing-codex-threshold.sh
# Tests: bin/review-plan-codex, skills/_shared/judge-task-complexity.md, hooks/workflow-state/complexity-routing.js, hooks/workflow-state/skip-signal-resolver/condition-schemas.js
# Tags: complexity, routing, stage, review-plan-codex, rubric, fail-open, scope:issue-specific
# Issue #2099 (#2723 split) — review-plan-codex plan-truncation threshold and rubric table.
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

case_begin "dispatch-case-files-codex-threshold" "bin/review-plan-codex"
. "$CASE_DIR/review-plan-codex-threshold-cases.sh"
. "$CASE_DIR/rubric-table-consistency.sh"
case_end

d2099_finish
