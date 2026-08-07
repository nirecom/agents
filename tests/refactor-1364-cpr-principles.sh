#!/bin/bash
# tests/refactor-1364-cpr-principles.sh
# Tests: rules/core-principles.md, CLAUDE.md, agents/supervisor.md, skills/survey-history/SKILL.md, agents/detail-planner.md, agents/detail-reviewer.md, agents/outline-reviewer.md, skills/survey-code/SKILL.md
# Tags: core-principles, refactor, scope:common
#
# Structural tests for issue #1364 — renumber core-principles.md sections to the
# CPR-N scheme, add CPR-SC "切り分けて考える" (separation-of-concerns) principle,
# and purge legacy §N cross-references from downstream prompt files.
#
# ALSO guards issue #1858 — the CPR-N numeric IDs are replaced by semantic short
# codes (CPR-UO, CPR-WPH, CPR-SC, CPR-SSOT, CPR-E2C, CPR-ORTH, CPR-E2E, CPR-NRS,
# CPR-UNV) in a fixed canonical order, and no residual CPR-<N> numeric ID may
# remain anywhere outside append-only historical records and lines carrying the
# line-scoped [CPR-LEGACY-ID-OK] allowlist marker (contract documented at
# CPR_LEGACY_ID_MARKER in refactor-1364-cpr-principles/mapping.sh). Both
# invariants are guarded here: #1364 established the scheme, #1858 renamed its
# members.
#
# Entrypoint only — the cases live in two sourced fragments (Pattern A split):
#   refactor-1364-cpr-principles/structure.sh — rules/core-principles.md itself
#   refactor-1364-cpr-principles/mapping.sh   — the downstream reference sweep
# This file owns what both fragments share: CORE, the section/occurrence helpers,
# the PASS/FAIL counters, run_all ordering, and the wall-clock timeout.
#
# fail-before-fix: authored before the source edits land. Many cases FAIL until
# rules/core-principles.md is renumbered and downstream files are updated.
#
# TL3 gap (what this test does NOT catch):
# - Whether the renamed principles reach a live planner/reviewer/Codex context —
#   this reads the file from disk, not the prompt a running agent receives.
# - Whether Claude Code honors CPR-WPH at runtime (does the model really state the
#   invariant before the mechanism?). Only visible in a real `claude -p` session.
# - Whether a skill that references core-principles.md silently stops loading it —
#   a dangling `CPR-ORTH` is text-visible here, a broken load is not.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration (the #1858 sweep
# edits skills/**/*.md, so the classifier raises "Did you run the skill end-to-end?").

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAGMENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/refactor-1364-cpr-principles"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Portable timeout: prefers `timeout`, falls back to perl alarm (macOS-safe).
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

CORE="$AGENTS_DIR/rules/core-principles.md"

# ----------------------------------------------------------------------------
# Shared helpers — used by BOTH fragments, so they live here, not in either one.
# ----------------------------------------------------------------------------

# Body of ONE CPR section: lines after its `## CPR-<code>` heading, up to the next
# `## ` heading. The `([ \t]|$)` boundary is mandatory — without it `E2C` matches the
# `CPR-E2E` heading and `UO` matches `CPR-UNV`, asserting against the wrong section.
cpr_section() {
    awk -v code="$1" '
        $0 ~ "^## CPR-" code "([ \t]|$)" { inside = 1; next }
        inside && /^## / { inside = 0 }
        inside { print }
    ' "$CORE"
}

ALL_CPR_CODES="CPR-UO CPR-WPH CPR-SC CPR-SSOT CPR-E2C CPR-ORTH CPR-E2E CPR-NRS CPR-UNV"

# Count OCCURRENCES (not matching lines) of one code in one file: `grep -o` emits one
# line per match, so a single line carrying two references counts as two. The trailing
# boundary keeps CPR-E2C from being counted as CPR-E2E (and any code from matching a
# longer sibling).
cpr_occurrences() {
    grep -oE "$1([^A-Za-z0-9]|\$)" "$2" 2>/dev/null | wc -l | tr -d ' '
}

# shellcheck source=tests/refactor-1364-cpr-principles/structure.sh
. "$FRAGMENT_DIR/structure.sh"
# shellcheck source=tests/refactor-1364-cpr-principles/mapping.sh
. "$FRAGMENT_DIR/mapping.sh"

# ============================================================================
# Run all (wrap in 120s wall-clock timeout if available)
# ============================================================================

run_all() {
    test_N1_all_cpr_headers_present
    test_N2_cpr_wph_new_principle
    test_N3_cpr_wph_content
    test_N4_downstream_no_legacy_section_ref
    test_L1_no_legacy_section_ref_in_core
    test_L2_no_old_numbered_header
    test_S1_exactly_9_cpr_headers
    test_S2_header_order
    test_S3_all_sections_non_empty
    test_S4_section_anchor_phrases
    test_G1_no_residual_numeric_cpr
    test_M1_downstream_mapping
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_CPR_TEST_INNER:-}" ]; then
        _CPR_TEST_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
