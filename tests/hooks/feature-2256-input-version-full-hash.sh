#!/usr/bin/env bash
# tests/hooks/feature-2256-input-version-full-hash.sh
# Tests: hooks/lib/diff-fingerprint.js, hooks/lib/branch-diff.js
# Tags: supervisor, input-version, freshness-key, content-hash, sha256, TL2, scope:issue-specific, pwsh-not-required

# TL3 gap (what this test does NOT catch):
# - a multi-gigabyte working tree where the hash cost itself changes hook timing
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

# #2256 S2-e / round-2 C2+C4: the version hashes FILE CONTENT, never diff text, and the
# digest is a full 64-hex sha256. Cases live in tests/hooks/feature-2256-input-version-full-hash/.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECTION_DIR="$AGENTS_ROOT/tests/hooks/feature-2256-input-version-full-hash"
RWT="$AGENTS_ROOT/bin/run-with-timeout.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }

# shellcheck source=./lib/section-runner.sh
. "$AGENTS_ROOT/tests/lib/section-runner.sh"

for tool in node git; do
    command -v "$tool" >/dev/null 2>&1 || fail "prereq-$tool" "$tool is required and must never be skipped"
done

run_section "digest-format.sh" 180
run_section "content-kinds.sh" 300
run_section "artifact-and-freshness.sh" 180
run_section "null-collapse-characterization.sh" 180

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && { echo "All tests passed."; exit 0; }
exit 1
