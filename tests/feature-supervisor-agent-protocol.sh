#!/usr/bin/env bash
# tests/feature-supervisor-agent-protocol.sh
# Tests: agents/supervisor.md
# Tags: scope:issue-specific, pwsh-not-required
# L3 gap (what this test does NOT catch):
# - The actual supervisor subagent following the new protocol at runtime
# - Whether removed Phase labels affect real subagent invocation behavior
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

# C9 [LOW]: Static checks on agents/supervisor.md:
#   (a) Phase 1/2/3 section labels removed (RED-EXPECTED until /write-code implements)
#   (b) bin/supervisor-review-codex --generate reference present (GREEN — already present)

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPERVISOR_MD="$AGENTS_DIR/agents/supervisor.md"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

if [ ! -f "$SUPERVISOR_MD" ]; then
    skip "C9-all: agents/supervisor.md not found"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# --- C9a: supervisor.md must NOT contain standalone Phase N labels ---
# After implementation, "### Phase 1", "### Phase 2", "### Phase 3" should be removed.
# RED-EXPECTED until /write-code removes the labels.
run_c9a() {
    local found
    found=$(grep -iE "^#{1,4} Phase [123]( |$|:)" "$SUPERVISOR_MD" 2>/dev/null || true)
    if [ -n "$found" ]; then
        fail "C9a [RED-EXPECTED]: supervisor.md still contains Phase N section labels (not yet removed):"$'\n'"$found"
    else
        pass "C9a: no standalone 'Phase N' section labels found in supervisor.md"
    fi
}

# --- C9b: supervisor.md must reference bin/supervisor-review-codex (Codex-primary instruction) ---
# GREEN with current source — the reference is already present.
run_c9b() {
    if grep -qF "bin/supervisor-review-codex" "$SUPERVISOR_MD" 2>/dev/null; then
        pass "C9b: agents/supervisor.md references bin/supervisor-review-codex (Codex-primary present)"
    else
        fail "C9b [RED-EXPECTED]: agents/supervisor.md does not reference bin/supervisor-review-codex"
    fi
}

run_c9a
run_c9b

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
