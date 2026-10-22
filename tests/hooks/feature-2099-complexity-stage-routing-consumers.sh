#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing-consumers.sh
# Tests: hooks/workflow-state/complexity-routing.js, bin/workflow/read-complexity-evaluation, bin/workflow/read-session-facts, bin/workflow/derive-complexity-level, skills/_shared/judge-task-complexity.md, skills/clarify-intent/SKILL.md, skills/workflow-init/SKILL.md, skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md
# Tags: complexity, routing, stage, consumers, producers, live-judge, tl3, scope:issue-specific
# Issue #2099 (#2723 split) — consumer/producer orchestration, legacy records, TL3-gated live cases.
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

case_begin "dispatch-case-files-consumers" "skills/make-detail-plan/SKILL.md"
# Builds the isolated broken-table tree ($D2099_ISO) that legacy-record-cases.sh (L-7) reuses.
. "$CASE_DIR/fail-open-cases.sh"
. "$CASE_DIR/consumers-static.sh"
. "$CASE_DIR/consumer-dispatch-cases.sh"
# Helper-only, sourced first: which read CLI each consumer documents, D2099_CONSUMERS, d2099sf_read.
. "$CASE_DIR/consumer-read-cli.sh"
. "$CASE_DIR/consumer-orchestration-cases.sh"
# The next two reuse the orchestration helpers (command extraction, model mapping).
. "$CASE_DIR/consumer-fallback-cases.sh"
. "$CASE_DIR/consumer-signal-forwarding-cases.sh"
. "$CASE_DIR/producer-orchestration-cases.sh"
. "$CASE_DIR/legacy-record-cases.sh"
. "$CASE_DIR/prompt-injection-cases.sh"
. "$CASE_DIR/judge-threshold-live-cases.sh"
# The next two reuse every d2099j_* helper above and the producer/consumer helpers.
. "$CASE_DIR/judge-boundary-live-cases.sh"
. "$CASE_DIR/live-e2e-cases.sh"
# Sourced last: it re-sources the two live case files inside a harness.
. "$CASE_DIR/tl3-gate-cases.sh"
case_end

d2099_finish
