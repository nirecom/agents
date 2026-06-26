#!/bin/bash
# Tests: skills/workflow-init/scripts/filter-primary-candidates.sh
# Tags: workflow-init, filter-primary-candidates, primary-detection, parent-filter, closed-filter, scope:issue-specific
#
# Feature 1005 — filter-primary-candidates.sh (NEW WI-3 primary-candidate
# filter). The script takes a list of candidate issue numbers (the `#N`
# matches WI-3 detected) and emits the subset eligible to be the session
# primary, one number per line, in input order. Two exclusion axes:
#   - CLOSED filter: a candidate whose issue-state-check.sh reports "closed"
#     is dropped (a closed issue is not a valid new primary).
#   - parent filter: a candidate A that is the PARENT of another candidate B
#     (i.e. B's parentIssue == A) is dropped — the child B is the more specific
#     work item, so the parent is not proposed as primary.
# Fallback: if every candidate is filtered out, emit the ORIGINAL candidate list
# unchanged (never return an empty primary set). Output order = input order.
#
# The script does not exist yet (created by /write-code). All FP-* cases are RED
# until then; the existence gate reports each as a clean failure (no crash).
#
# Mock contract (matches closed-detection.sh's helper convention):
#   issue-state-check.sh <N>  → prints MOCK_STATE_<N> (default "open").
#   gh issue view <N> --json parent  → {"parent":{"number":M}} from
#     GH_MOCK_PARENT_<N> (default null). Value "fail" → gh exits 1 (fail-open).
#
# L3 gap (what these tests do NOT catch):
# - Whether the real issue-state-check.sh / gh parent linkage match the mock
#   shapes against a live GitHub repo.
# - Whether WI-3 invokes filter-primary-candidates.sh correctly in a live
#   workflow-init session and renders the surviving primary set.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$AGENTS_DIR/skills/workflow-init/scripts/filter-primary-candidates.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"; fi
}

# Guard helper: run the SUT only if present; otherwise record a RED failure
# without invoking a missing file (keeps the runner from crashing).
require_sut() {  # arg: case-label
    if [ -x "$SUT" ] || [ -f "$SUT" ]; then return 0; fi
    fail "$1: filter-primary-candidates.sh not found at $SUT (RED until /write-code)"
    return 1
}

setup_mock() {
    TMP="$(mktemp -d 2>/dev/null || mktemp -d -t filtprim)"
    mkdir -p "$TMP/mock-bin" "$TMP/bin/github-issues"

    # gh mock: `gh issue view <N> --json parent` → parent JSON per-N.
    cat > "$TMP/mock-bin/gh" <<'MOCKGH'
#!/bin/bash
sub1="${1:-}"; sub2="${2:-}"
if [ "$sub1" = "issue" ] && [ "$sub2" = "view" ]; then
    N="${3:-}"
    VARNAME="GH_MOCK_PARENT_${N}"
    VAL="${!VARNAME:-}"
    if [ "$VAL" = "fail" ]; then echo "mock parent fail" >&2; exit 1; fi
    if [ -z "$VAL" ]; then echo '{"parent":null}'; else echo "$VAL"; fi
    exit 0
fi
echo '{}'
exit 0
MOCKGH
    chmod +x "$TMP/mock-bin/gh"

    # issue-state-check.sh mock: prints MOCK_STATE_<N> (default open).
    cat > "$TMP/bin/github-issues/issue-state-check.sh" <<'MOCKSTATE'
#!/bin/bash
N="${1:-}"
VARNAME="MOCK_STATE_${N}"
VAL="${!VARNAME:-}"
if [ "$VAL" = "fail" ]; then exit 1; fi
echo "${VAL:-open}"
exit 0
MOCKSTATE
    chmod +x "$TMP/bin/github-issues/issue-state-check.sh"

    export AGENTS_CONFIG_DIR="$TMP"
    export PATH="$TMP/mock-bin:$PATH"
}

teardown_mock() {
    PATH="${PATH#$TMP/mock-bin:}"
    export PATH
    rm -rf "$TMP" 2>/dev/null || true
    for v in $(env | grep -oE '^MOCK_STATE_[0-9]+' || true); do unset "$v"; done
    for v in $(env | grep -oE '^GH_MOCK_PARENT_[0-9]+' || true); do unset "$v"; done
}

emitted() {  # args: OUT N → 0 if N present as a stdout line
    printf '%s\n' "$1" | grep -qx "$2"
}

# FP-1: all OPEN candidates, no parent relationships → all pass through.
setup_mock
if require_sut "FP-1"; then
    OUT=$(run_with_timeout 10 bash "$SUT" 301 302 303 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && emitted "$OUT" 301 && emitted "$OUT" 302 && emitted "$OUT" 303; then
        pass "FP-1: all OPEN, no parents → all three emitted"
    else
        fail "FP-1: expected 301/302/303 all present; got rc=$RC out=$OUT"
    fi
fi
teardown_mock

# FP-2: CLOSED candidate → excluded.
setup_mock
export MOCK_STATE_302=closed
if require_sut "FP-2"; then
    OUT=$(run_with_timeout 10 bash "$SUT" 301 302 303 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && emitted "$OUT" 301 && ! emitted "$OUT" 302 && emitted "$OUT" 303; then
        pass "FP-2: CLOSED #302 excluded; 301/303 kept"
    else
        fail "FP-2: expected 302 absent, 301/303 present; got rc=$RC out=$OUT"
    fi
fi
teardown_mock

# FP-3: candidate A (#301) is the parent of candidate B (#302) → A excluded,
# B remains. B's parentIssue == A is the signal.
setup_mock
export GH_MOCK_PARENT_302='{"parent":{"number":301}}'
if require_sut "FP-3"; then
    OUT=$(run_with_timeout 10 bash "$SUT" 301 302 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && ! emitted "$OUT" 301 && emitted "$OUT" 302; then
        pass "FP-3: parent #301 (of #302) excluded; child #302 kept"
    else
        fail "FP-3: expected 301 absent, 302 present; got rc=$RC out=$OUT"
    fi
fi
teardown_mock

# FP-4: candidate B (#302) is a child (its parent #999 is NOT among candidates)
# → B not excluded (only a parent-OF-a-candidate is dropped, not a child).
setup_mock
export GH_MOCK_PARENT_302='{"parent":{"number":999}}'
if require_sut "FP-4"; then
    OUT=$(run_with_timeout 10 bash "$SUT" 301 302 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && emitted "$OUT" 301 && emitted "$OUT" 302; then
        pass "FP-4: child #302 (parent #999 not a candidate) kept"
    else
        fail "FP-4: expected 301/302 present; got rc=$RC out=$OUT"
    fi
fi
teardown_mock

# FP-5: all candidates CLOSED → filter empties the set → fallback: emit ALL
# original candidates unchanged.
setup_mock
export MOCK_STATE_301=closed
export MOCK_STATE_302=closed
if require_sut "FP-5"; then
    OUT=$(run_with_timeout 10 bash "$SUT" 301 302 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && emitted "$OUT" 301 && emitted "$OUT" 302; then
        pass "FP-5: all CLOSED → fallback emits original 301/302"
    else
        fail "FP-5: expected fallback 301/302; got rc=$RC out=$OUT"
    fi
fi
teardown_mock

# FP-6: after filter exactly 1 candidate remains → stdout contains only that 1.
setup_mock
export MOCK_STATE_302=closed
export MOCK_STATE_303=closed
if require_sut "FP-6"; then
    OUT=$(run_with_timeout 10 bash "$SUT" 301 302 303 2>/dev/null)
    RC=$?
    COUNT=$(printf '%s\n' "$OUT" | grep -cE '^[0-9]+$' || true)
    if [ "$RC" -eq 0 ] && [ "$COUNT" -eq 1 ] && emitted "$OUT" 301; then
        pass "FP-6: exactly 1 survivor → stdout is only #301"
    else
        fail "FP-6: expected single line 301; got rc=$RC count=$COUNT out=$OUT"
    fi
fi
teardown_mock

# FP-7: CLOSED filter + parent filter both active → correct subset.
# #301 parent-of #302 (excluded by parent filter); #303 CLOSED (excluded);
# #302 OPEN child (kept); #304 OPEN unrelated (kept).
setup_mock
export GH_MOCK_PARENT_302='{"parent":{"number":301}}'
export MOCK_STATE_303=closed
if require_sut "FP-7"; then
    OUT=$(run_with_timeout 10 bash "$SUT" 301 302 303 304 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] \
       && ! emitted "$OUT" 301 && emitted "$OUT" 302 \
       && ! emitted "$OUT" 303 && emitted "$OUT" 304; then
        pass "FP-7: parent #301 + CLOSED #303 excluded; #302/#304 kept"
    else
        fail "FP-7: expected 301/303 absent, 302/304 present; got rc=$RC out=$OUT"
    fi
fi
teardown_mock

# FP-8: gh issue view fails for one candidate → fail-open (treated as no parent,
# stays in output based on its OPEN state).
setup_mock
export GH_MOCK_PARENT_302=fail
if require_sut "FP-8"; then
    OUT=$(run_with_timeout 10 bash "$SUT" 301 302 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && emitted "$OUT" 301 && emitted "$OUT" 302; then
        pass "FP-8: gh parent fetch fail → fail-open, #302 kept"
    else
        fail "FP-8: expected 301/302 present (fail-open); got rc=$RC out=$OUT"
    fi
fi
teardown_mock

# FP-9: output order preserves the input argument order.
setup_mock
if require_sut "FP-9"; then
    OUT=$(run_with_timeout 10 bash "$SUT" 303 301 302 2>/dev/null)
    RC=$?
    ORDER=$(printf '%s\n' "$OUT" | grep -E '^[0-9]+$' | tr '\n' ' ' | sed 's/ *$//')
    if [ "$RC" -eq 0 ] && [ "$ORDER" = "303 301 302" ]; then
        pass "FP-9: output preserves input order (303 301 302)"
    else
        fail "FP-9: expected order '303 301 302'; got rc=$RC order='$ORDER' out=$OUT"
    fi
fi
teardown_mock

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
