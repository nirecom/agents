#!/bin/bash
# tests/fix-supervisor-c2-label-891-892-phase4.sh
# Tests: agents/supervisor.md (Phase 4 dispatch detection JD checklist item)
# Tags: supervisor, em-supervisor, layer2, fix
# RED for issue #892 (add 6th JD checklist item for /issue-create Phase 4 detection).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPERVISOR_MD="$AGENTS_DIR/agents/supervisor.md"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# Extract the JD Checklist section block: from "## Layer 2 JD Checklist" to next "## " header.
extract_checklist() {
    awk '/^## Layer 2 JD Checklist/{flag=1; next} flag && /^## /{flag=0} flag' "$SUPERVISOR_MD"
}

run_p1() {
    local label="P1: agents/supervisor.md JD checklist contains a 6th item (numbered '6.')"
    if extract_checklist | grep -qE '^6\. '; then
        pass "$label"
    else
        fail "$label"
    fi
}

run_p2() {
    local label="P2: 6th item mentions ISSUE_CREATE_SKILL or issue-create-dispatch.sh"
    local block
    block="$(extract_checklist)"
    if echo "$block" | grep -qE 'ISSUE_CREATE_SKILL|issue-create-dispatch\.sh'; then
        pass "$label"
    else
        fail "$label"
    fi
}

run_p3() {
    local label="P3: JD checklist mentions 'gh issue list --state all'"
    if extract_checklist | grep -q 'gh issue list --state all'; then
        pass "$label"
    else
        fail "$label"
    fi
}

run_p4() {
    local label="P4: JD checklist mentions 'gh issue view' (candidate inspection)"
    if extract_checklist | grep -q 'gh issue view'; then
        pass "$label"
    else
        fail "$label"
    fi
}

run_p1
run_p2
run_p3
run_p4

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
