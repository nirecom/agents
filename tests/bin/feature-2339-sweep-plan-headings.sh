#!/usr/bin/env bash
# tests/bin/feature-2339-sweep-plan-headings.sh
# Tests: bin/sweep-plan-headings.js
# Tags: scope:issue-specific, TL2
# lang-check: ignore -- CJK heading fixtures are built inside node here.
# TL2 CLI tests for the plan-heading sweep (#2339): dry-run is non-destructive;
# --fix normalizes localized H2 headings to canonical English (plan-schema SSOT),
# reorders ONLY known canonical outline sections, leaves non-outline and unknown
# H2 sections in place, and preserves H1/preamble/bodies. RED until the tool exists.

# TL3 gap: no --all sweep of a real plans dir with concurrent writers, and no
# PLAN_LANG variants beyond the LOCALIZED_TO_CANONICAL table.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SWEEP="$AGENTS_ROOT/bin/sweep-plan-headings.js"
PLAN_SCHEMA="$AGENTS_ROOT/hooks/lib/plan-schema.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not available"
    echo "Results: 0/0 passed, 0 failed"
    exit 0
fi

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

to_node() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
SWEEP_NODE="$(to_node "$SWEEP")"
PLAN_SCHEMA_NODE="$(to_node "$PLAN_SCHEMA")"
TMP_NODE="$(to_node "$TMPDIR_BASE")"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=./feature-2339-sweep-plan-headings/d-tests.sh
. "$SCRIPT_DIR/feature-2339-sweep-plan-headings/d-tests.sh"
# shellcheck source=./feature-2339-sweep-plan-headings/c7-tests.sh
. "$SCRIPT_DIR/feature-2339-sweep-plan-headings/c7-tests.sh"
# shellcheck source=./feature-2339-sweep-plan-headings/c8-tests.sh
. "$SCRIPT_DIR/feature-2339-sweep-plan-headings/c8-tests.sh"
# shellcheck source=./feature-2339-sweep-plan-headings/c9-c5-c6-tests.sh
. "$SCRIPT_DIR/feature-2339-sweep-plan-headings/c9-c5-c6-tests.sh"

TOTAL=$((PASS + FAIL))
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
