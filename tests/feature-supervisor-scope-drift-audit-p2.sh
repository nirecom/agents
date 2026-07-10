#!/usr/bin/env bash
# tests/feature-supervisor-scope-drift-audit-p2.sh
# Tests: hooks/workflow-gate.js (checkSupervisorPreMerge Path ii), hooks/lib/supervisor-state-writer.js
# Tags: supervisor, em-supervisor, workflow-gate, scope-drift, audit, scope:issue-specific, pwsh-not-required, hook-registration
# L3 gap (what this test does NOT catch):
# - workflow-gate.js firing as a real PreToolUse hook (hook registration via settings.json)
# - Real git push intercepted in a live Claude Code session
# - resolveBranchDiff using origin/* refs that require a real remote — this test stubs
#   refs/remotes/origin/main locally via update-ref, not a live fetch
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

# C3: scope-drift path (Path ii) must fire WITHOUT any warning-flush (Path i) contribution.
# Unlike T8-all-declared (which seeds a warning finding → Path i fires first), this test
# seeds NO supervisor state file at all. resolveSupervisorState returns an empty state
# with no cumulative_severity, so Path i is skipped and only Path ii (scope-drift) can block.
# The branch diff contains an undeclared file → scope-drift:pre-merge block is asserted.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/workflow-gate.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
WFSTATE_NODE="$_AGENTS_DIR_NODE/hooks/lib/workflow-state.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'supvsr6p2'; }

if [ ! -f "$HOOK" ]; then
    skip "C3: workflow-gate.js not present"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi
if ! command -v node >/dev/null 2>&1; then
    skip "C3: node not available"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi
if ! grep -q "scope-drift" "$HOOK" 2>/dev/null; then
    skip "C3: scope-drift not present in workflow-gate.js"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# Fixture: main has one declared file; feature branch adds an UNDECLARED file.
# origin/main ref is stubbed locally so merge-base resolves without a live remote.
setup_git_fixture() {
    local repodir="$1"
    git -C "$repodir" init -b main >/dev/null 2>&1 || git -C "$repodir" init >/dev/null 2>&1
    git -C "$repodir" config user.email "test@example.com" >/dev/null 2>&1
    git -C "$repodir" config user.name "Test" >/dev/null 2>&1
    # Disable inherited global core.hooksPath (throwaway fixture repo — bypass is safe).
    git -C "$repodir" config core.hooksPath /dev/null >/dev/null 2>&1
    mkdir -p "$repodir/hooks"
    echo "declared" > "$repodir/hooks/workflow-gate.js"
    git -C "$repodir" add . >/dev/null 2>&1
    git -C "$repodir" commit --no-verify -m "base" >/dev/null 2>&1
    git -C "$repodir" switch -c feature-test >/dev/null 2>&1 || git -C "$repodir" checkout -b feature-test >/dev/null 2>&1
    echo "undeclared" > "$repodir/hooks/supervisor-guard.js"
    git -C "$repodir" add . >/dev/null 2>&1
    git -C "$repodir" commit --no-verify -m "add undeclared file" >/dev/null 2>&1
    git -C "$repodir" update-ref refs/remotes/origin/main HEAD~ >/dev/null 2>&1 || true
}

write_detail_fixture() {
    local plansdir="$1" wsid="$2"
    mkdir -p "$plansdir"
    cat > "$plansdir/${wsid}-detail.md" <<'DETAIL'
# Implementation Detail Plan

## Files to modify

- `hooks/workflow-gate.js` — main merge gate

## Steps

Step 1: do something.
DETAIL
}

seed_wf_state() {
    local tmp_node="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const wf = require('$WFSTATE_NODE');
wf.markStep('$sid', 'user_verification', 'complete');
" >/dev/null 2>&1
}

read_audit_field() {
    local tmp_node="$1" sid="$2" field="$3"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
process.stdout.write(String((st && st.audit && st.audit['$field']) || 'null'));
" 2>/dev/null
}

# --- C3: no supervisor state seeded → only Path ii (scope-drift) can block ---
run_c3_scope_drift_only() {
    local tmp sid wsid repodir tmp_node repodir_node hook_input out audit_cause audit_phase
    tmp=$(make_tmp)
    sid="c3-sid-$$"
    wsid="c3-wsid-$$"
    repodir="$tmp/repo"
    mkdir -p "$repodir/hooks"
    if command -v cygpath >/dev/null 2>&1; then
        tmp_node="$(cygpath -m "$tmp")"
        repodir_node="$(cygpath -m "$repodir")"
    else
        tmp_node="$tmp"
        repodir_node="$repodir"
    fi

    setup_git_fixture "$repodir"
    write_detail_fixture "$tmp" "$wsid"
    seed_wf_state "$tmp_node" "$sid"
    # NOTE: no seed_supervisor_state — no state file exists → no cumSev → Path i skipped.

    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr merge --squash","cwd":"%s"}}' "$sid" "$repodir_node")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        WORKFLOW_SESSION_ID="$wsid" \
        run_with_timeout 15 node "$HOOK" <<< "$hook_input" 2>/dev/null)

    audit_cause=$(read_audit_field "$tmp_node" "$sid" "audit_cause")
    audit_phase=$(read_audit_field "$tmp_node" "$sid" "audit_phase")

    rm -rf "$tmp"

    if ! echo "$out" | grep -q '"decision":"block"'; then
        fail "C3: no-state scope-drift must block via Path ii (undeclared branch file), got: $(printf '%q' "${out:0:80}")"
        return
    fi
    if [ "$audit_cause" != "scope-drift:pre-merge" ]; then
        fail "C3: audit_cause must be 'scope-drift:pre-merge' (not warning-flush), got '$audit_cause'"
        return
    fi
    if [ "$audit_phase" != "pending" ]; then
        fail "C3: audit_phase must be 'pending', got '$audit_phase'"
        return
    fi
    pass "C3: no supervisor state + undeclared branch file → scope-drift:pre-merge block (Path ii only)"
}
run_c3_scope_drift_only

# --- Table-driven tests for parseDetailFilesToModify (exported from workflow-gate.js) ---
# Cases:
#   1. two declared files → array of both paths
#   2. empty "## Files to modify" section → []
#   3. missing "## Files to modify" section → []
#   4. null plansDir → null
#   5. plansDir exists but detail.md missing → null
run_parse_detail_table() {
    local tmp tmp_node sid result
    tmp=$(make_tmp)
    if command -v cygpath >/dev/null 2>&1; then
        tmp_node="$(cygpath -m "$tmp")"
    else
        tmp_node="$tmp"
    fi

    call_parser() {
        local plans="$1" wsid="$2"
        run_with_timeout 5 node -e "
const {parseDetailFilesToModify} = require('$_AGENTS_DIR_NODE/hooks/workflow-gate.js');
const arg = ('$plans' === '__NULL__') ? null : '$plans';
const r = parseDetailFilesToModify(arg, '$wsid');
process.stdout.write(JSON.stringify(r));
" 2>/dev/null
    }

    # Case 1: two declared files
    sid="pd-two-$$"
    cat > "$tmp/${sid}-detail.md" <<'DETAIL'
# Implementation Detail Plan

## Files to modify

- `hooks/workflow-gate.js` — main merge gate
- `hooks/supervisor-guard.js` — stop guard

## Steps

Step 1: do something.
DETAIL
    result=$(call_parser "$tmp_node" "$sid")
    if [ "$result" = '["hooks/workflow-gate.js","hooks/supervisor-guard.js"]' ]; then
        pass "parseDetail-1: two declared files → both paths"
    else
        fail "parseDetail-1: expected both paths, got '$result'"
    fi

    # Case 2: empty section (header present, no backtick lines)
    sid="pd-empty-$$"
    cat > "$tmp/${sid}-detail.md" <<'DETAIL'
# Implementation Detail Plan

## Files to modify

## Steps

Step 1: do something.
DETAIL
    result=$(call_parser "$tmp_node" "$sid")
    if [ "$result" = '[]' ]; then
        pass "parseDetail-2: empty section → []"
    else
        fail "parseDetail-2: expected [], got '$result'"
    fi

    # Case 3: missing section entirely
    sid="pd-nosec-$$"
    cat > "$tmp/${sid}-detail.md" <<'DETAIL'
# Implementation Detail Plan

## Steps

Step 1: do something.
DETAIL
    result=$(call_parser "$tmp_node" "$sid")
    if [ "$result" = '[]' ]; then
        pass "parseDetail-3: missing section → []"
    else
        fail "parseDetail-3: expected [], got '$result'"
    fi

    # Case 4: null plansDir
    result=$(call_parser "__NULL__" "some-sid")
    if [ "$result" = 'null' ]; then
        pass "parseDetail-4: null plansDir → null"
    else
        fail "parseDetail-4: expected null, got '$result'"
    fi

    # Case 5: plansDir exists but detail.md missing
    result=$(call_parser "$tmp_node" "pd-missing-$$")
    if [ "$result" = 'null' ]; then
        pass "parseDetail-5: file not found → null"
    else
        fail "parseDetail-5: expected null, got '$result'"
    fi

    rm -rf "$tmp"
}
run_parse_detail_table

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
