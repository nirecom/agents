#!/bin/bash
# tests/feature-1236-scan-outbound-target.sh
# Tests: hooks/lib/forge-write-extract.js, hooks/scan-outbound.js
# Tags: hook, scan, github, security, scope:issue-specific, pwsh-not-required
#
# Dispatcher for the forge-write target-visibility gate test suite.
# Sub-files:
#   feature-1236-scan-outbound-target/part-a.sh — extractRepoFlag(command) unit
#     (table-driven, node driver).
#   feature-1236-scan-outbound-target/part-b.sh — scan-outbound.js integration:
#     public-target leak blocked, private-target skips private-info scan but still
#     runs offensive, dynamic WARN (Bash + Edit/Write), body cannot redirect target.
#
# Security boundary:
#   - Public target + static-blocklisted content → HARD block
#   - Public target + dynamic-only (listPrivateRepoNames) content → WARN block
#   - Private target → private-info scan skipped, offensive scanner runs regardless
#   - HARD takes precedence over WARN when both match
#
# L3 gap (what this test does NOT catch):
# - real gh API call against live GitHub repos (target visibility via real network)
# - cwd-based target resolution when no --repo flag present (fragile at L2 — noted SKIPPED)
# - cache TTL behaviour under concurrent hook invocations
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_DIR="$TESTS_DIR/feature-1236-scan-outbound-target"
TOTAL_PASS=0
TOTAL_FAIL=0

run_sub() {
    local out; out="$(bash "$1" 2>&1)"
    printf '%s\n' "$out"
    local p f
    p=$(printf '%s\n' "$out" | grep -c '^PASS:' || true)
    f=$(printf '%s\n' "$out" | grep -c '^FAIL:' || true)
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + f))
}

run_sub "$SUB_DIR/part-a.sh"
run_sub "$SUB_DIR/part-b.sh"

echo ""
echo "================================"
echo "Total: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL"
exit $TOTAL_FAIL
