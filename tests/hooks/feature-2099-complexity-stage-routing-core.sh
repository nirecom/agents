#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing-core.sh
# Tests: hooks/workflow-state/complexity-routing.js, hooks/workflow-state/complexity-routing/secret-shape.js, hooks/workflow-state.js, hooks/workflow-state/state-io/session-fields.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/migrations/v1-to-v2.js, hooks/workflow-state/skip-signal-resolver.js, hooks/workflow-state/skip-signal-resolver/complexity.js, hooks/workflow-state/skip-signal-resolver/condition-schemas.js, bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation, bin/workflow/derive-complexity-level
# Tags: complexity, routing, stage, workflow-state, cli, fail-open, scope:issue-specific
# Issue #2099 (#2723 split) — derivation, secret-shape, derive CLI and record/read cases.
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

case_begin "dispatch-case-files-core" "hooks/workflow-state/complexity-routing.js"
. "$CASE_DIR/derivation-cases.sh"
. "$CASE_DIR/validate-table-cases.sh"
. "$CASE_DIR/combination-escalation-cases.sh"
. "$CASE_DIR/secret-shape-classifier-cases.sh"
# Reuses SS_MOD_N and SS_REDACT_PRELUDE from the classifier cases.
. "$CASE_DIR/secret-shape-midword-key-cases.sh"
. "$CASE_DIR/secret-shape-scanner-parity-cases.sh"
. "$CASE_DIR/derive-cli-output-mode-cases.sh"
. "$CASE_DIR/record-read-cases.sh"
# The next three reuse record-read-cases.sh helpers (state probes, raw-event injection).
. "$CASE_DIR/record-read-readback-cases.sh"
. "$CASE_DIR/record-read-history-cases.sh"
. "$CASE_DIR/invalid-levels-atomicity-cases.sh"
. "$CASE_DIR/writer-api-arg-cases.sh"
# #2460 retired the zero-signal auto-skip: these pin that no record skips outline/detail.
. "$CASE_DIR/skip-aggregate-cases.sh"
. "$CASE_DIR/skip-delegation-cases.sh"
case_end

d2099_finish
