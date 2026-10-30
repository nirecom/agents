#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing-fallback-forwarding.sh
# Tests: hooks/workflow-state/complexity-routing.js, bin/workflow/derive-complexity-level, bin/workflow/read-complexity-evaluation, bin/workflow/read-session-facts, skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md
# Tags: complexity, routing, stage, consumers, fallback, signals-file, scope:issue-specific
# Issue #2099 (#2723 split) — the NONE fallback chain and its per-stage signals-file forwarding.
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

case_begin "dispatch-case-files-fallback-forwarding" "bin/workflow/derive-complexity-level"
# Helper-only, sourced first: D2099_CONSUMERS, d2099_consumer_read, d2099sf_read.
. "$CASE_DIR/consumer-read-cli.sh"
# The fallback chain: the shared two-stage procedure each skill names, run verbatim (#2460).
. "$CASE_DIR/consumer-normalize-chain.sh"
# Reuses the d2099n_* chain helpers above.
. "$CASE_DIR/consumer-fallback-forwarding-cases.sh"
case_end

d2099_finish
