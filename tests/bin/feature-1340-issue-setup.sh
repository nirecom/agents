#!/bin/bash
# tests/bin/feature-1340-issue-setup.sh
# Tests: bin/github-issues/sync-labels.sh, bin/github-issues/lib/resolve-project.sh, bin/github-issues/lib/ensure-project-ready.sh, bin/github-issues/issue-create-preflight.sh, bin/github-issues/issue-create.sh, bin/github-issues/wip-state.sh, skills/migrate-tracker/scripts/run-issue-setup.sh
# Tags: migrate-tracker, sync-labels, resolve-project, ensure-project-ready, wip-state, scope:issue-specific
# Dispatch + aggregate entrypoint; logic lives in tests/bin/feature-1340-issue-setup/ (each group runs standalone).
# TL3 gap (what this test does NOT catch):
# - Whether /migrate-tracker invokes run-issue-setup.sh correctly in a live session, or its repo-confirm AskUserQuestion.
# - Whether issue-create.sh Phase 0a auto-repair works against a real GitHub API.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -euo pipefail

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
# Groups share no state (each owns its mktemp fixture root), so they run in
# parallel; logs are buffered per group and printed in SPLIT_GROUPS order.
OUT_DIR="$(mktemp -d)"; readonly OUT_DIR
trap 'rm -rf "$OUT_DIR"' EXIT
TOTAL_PASS=0; TOTAL_FAIL=0; declare -A PIDS=()
for group in "${SPLIT_GROUPS[@]}"; do
    [[ -f "$SPLIT_DIR/$group" ]] && { bash "$SPLIT_DIR/$group" >"$OUT_DIR/$group.log" 2>&1 & PIDS[$group]=$!; }
done

re='^Results: ([0-9]+) passed, ([0-9]+) failed'
for group in "${SPLIT_GROUPS[@]}"; do
    if [[ -z "${PIDS[$group]:-}" ]]; then
        echo "FAIL: split group missing: $SPLIT_DIR/$group"; TOTAL_FAIL=$((TOTAL_FAIL + 1)); continue
    fi
    rc=0; wait "${PIDS[$group]}" || rc=$?
    printf '\n═══ %s ═══\n' "$group"; results_line=""
    while IFS= read -r line; do
        printf '%s\n' "$line"; [[ "$line" =~ $re ]] && results_line="$line"
    done <"$OUT_DIR/$group.log"
    if [[ "$results_line" =~ $re ]]; then
        TOTAL_PASS=$((TOTAL_PASS + BASH_REMATCH[1])); TOTAL_FAIL=$((TOTAL_FAIL + BASH_REMATCH[2]))
    else
        echo "WARN: $group emitted no Results line (exit=$rc); counting as 1 failure"; TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
done
printf '\n═════════════════════════════════════════\n'
echo "Aggregate Results: $TOTAL_PASS passed, $TOTAL_FAIL failed"
[[ "$TOTAL_FAIL" -eq 0 ]]
