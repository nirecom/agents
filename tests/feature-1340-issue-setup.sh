#!/bin/bash
# tests/feature-1340-issue-setup.sh
# Tests: bin/github-issues/sync-labels.sh, bin/github-issues/lib/resolve-project.sh, bin/github-issues/lib/ensure-project-ready.sh, bin/github-issues/issue-create-preflight.sh, bin/github-issues/issue-create.sh, bin/github-issues/wip-state.sh, skills/issue-setup/scripts/run-issue-setup.sh
# Tags: issue-setup, sync-labels, resolve-project, ensure-project-ready, wip-state, scope:issue-specific
#
# Dispatch + aggregate entrypoint for the feature-1340-issue-setup split suite.
# All logic lives in tests/feature-1340-issue-setup/ per rules/coding/file-split.md.
# Each split group also runs standalone.
#
# L3 gap (what this test does NOT catch):
# - Whether /issue-setup skill invokes run-issue-setup.sh correctly in a live
#   Claude Code session, or whether AskUserQuestion fires for repo confirmation.
# - Whether issue-create.sh Phase 0a auto-repair works against a real GitHub API.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

SPLIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1340-issue-setup"

SPLIT_GROUPS=(
    "sync-labels-repo-flag.sh"
    "resolve-project-schema.sh"
    "ensure-project-ready.sh"
    "wip-state-migration.sh"
    "issue-create-phase0a.sh"
    "issue-create-preflight.sh"
    "run-issue-setup.sh"
)

TOTAL_PASS=0
TOTAL_FAIL=0

for group in "${SPLIT_GROUPS[@]}"; do
    script="$SPLIT_DIR/$group"
    if [ ! -f "$script" ]; then
        echo "FAIL: split group missing: $script"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        continue
    fi

    echo ""
    echo "═══ $group ═══"
    out_file="$(mktemp)"
    bash "$script" 2>&1 | tee "$out_file"
    rc=${PIPESTATUS[0]}

    results_line="$(grep -E '^Results: [0-9]+ passed, [0-9]+ failed' "$out_file" | tail -1)"
    if [ -n "$results_line" ]; then
        g_pass="$(printf '%s' "$results_line" | sed -E 's/^Results: ([0-9]+) passed.*/\1/')"
        g_fail="$(printf '%s' "$results_line" | sed -E 's/.* ([0-9]+) failed.*/\1/')"
        TOTAL_PASS=$((TOTAL_PASS + g_pass))
        TOTAL_FAIL=$((TOTAL_FAIL + g_fail))
    else
        echo "WARN: $group emitted no Results line (exit=$rc); counting as 1 failure"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
    rm -f "$out_file"
done

echo ""
echo "═════════════════════════════════════════"
echo "Aggregate Results: $TOTAL_PASS passed, $TOTAL_FAIL failed"
[ "$TOTAL_FAIL" -eq 0 ] && exit 0 || exit 1
