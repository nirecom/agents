#!/bin/bash
# detect-sc7-tests.sh: bin/session-close-detect-wf-meta.js + bin/session-close-render-sc7.js
# Tests: bin/session-close-detect-wf-meta.js, bin/session-close-render-sc7.js
# Tags: scope:issue-specific
#
# Sourced helpers: feature-1463-session-close-scriptify/helpers.sh

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

test_T10_T11_no_args_exit1() {
    if [ ! -f "$DETECT_JS" ] || [ ! -f "$SC7_JS" ]; then skip "T10+T11 (arg-guard scripts missing)"; return; fi
    run_with_timeout 120 node "$DETECT_JS" >/dev/null 2>&1; local c1=$?
    run_with_timeout 120 node "$SC7_JS" >/dev/null 2>&1; local c2=$?
    if [ "$c1" = "1" ]; then pass "T10: detect no-args -> exit 1"; else fail "T10: expected exit 1, got $c1"; fi
    if [ "$c2" = "1" ]; then pass "T11: sc7 no-args -> exit 1"; else fail "T11: expected exit 1, got $c2"; fi
}

# T12: sc7 with nonexistent state path -> exit 0, empty stdout (fail-open: nothing to surface).
test_T12_sc7_absent_path_empty() {
    if [ ! -f "$SC7_JS" ]; then
        skip "T12_sc7_absent_path_empty (bin/session-close-render-sc7.js missing)"
        return
    fi
    local out code
    out="$(run_with_timeout 120 node "$SC7_JS" "${TMPDIR_BASE}/absent-supervisor-state.json" 2>/dev/null)"
    code=$?
    if [ "$code" = "0" ] && [ -z "$out" ]; then
        pass "T12_sc7_absent_path_empty: absent state path -> exit 0, empty stdout"
    else
        fail "T12_sc7_absent_path_empty: expected exit 0 + empty stdout, got exit $code, out='$out'"
    fi
}

test_T13_detect_wf_meta_yes() {
    if [ ! -f "$DETECT_JS" ]; then skip "T13_detect_wf_meta_yes (bin/session-close-detect-wf-meta.js missing)"; return; fi
    mkdir -p "${TMPDIR_BASE}/wf-state"
    printf '{"workflow_type":"wf-meta","steps":{}}\n' > "${TMPDIR_BASE}/wf-state/t13.json"
    local out; out="$(run_with_timeout 120 env CLAUDE_WORKFLOW_DIR="$(node_path "${TMPDIR_BASE}/wf-state")" node "$DETECT_JS" t13 2>/dev/null)"
    if [ "$out" = "yes" ]; then pass "T13_detect_wf_meta_yes: wf-meta state -> 'yes'"; else fail "T13_detect_wf_meta_yes: expected 'yes', got '$out'"; fi
}
test_T14_detect_wf_meta_no() {
    if [ ! -f "$DETECT_JS" ]; then skip "T14_detect_wf_meta_no (bin/session-close-detect-wf-meta.js missing)"; return; fi
    printf '{"workflow_type":"wf-code","steps":{}}\n' > "${TMPDIR_BASE}/wf-state/t14.json"
    local out; out="$(run_with_timeout 120 env CLAUDE_WORKFLOW_DIR="$(node_path "${TMPDIR_BASE}/wf-state")" node "$DETECT_JS" t14 2>/dev/null)"
    if [ "$out" = "no" ]; then pass "T14_detect_wf_meta_no: wf-code state -> 'no'"; else fail "T14_detect_wf_meta_no: expected 'no', got '$out'"; fi
}
test_T17_detect_no_state() {
    if [ ! -f "$DETECT_JS" ]; then skip "T17_detect_no_state (bin/session-close-detect-wf-meta.js missing)"; return; fi
    local out code; out="$(run_with_timeout 120 env CLAUDE_WORKFLOW_DIR="$(node_path "${TMPDIR_BASE}/wf-state")" node "$DETECT_JS" no-state-t17 2>/dev/null)"; code=$?
    if [ "$out" = "no" ] && [ "$code" = "0" ]; then pass "T17_detect_no_state: missing state -> 'no', exit 0"; else fail "T17_detect_no_state: expected 'no'/exit 0, got '$out'/exit $code"; fi
}
test_T15_T18_sc7_variants() {
    if [ ! -f "$SC7_JS" ]; then skip "T15_T18_sc7_variants (bin/session-close-render-sc7.js missing)"; return; fi
    local sf="${TMPDIR_BASE}/sc7-t15.json" out
    printf '{"alert":{"findings":[{"categories":["workflow"],"severity":"warning","detail":"test"}],"findings_surfaced_at":null},"layer1":{"findings":[]},"audit":{"findings":[]}}\n' > "$sf"
    out="$(run_with_timeout 120 node "$SC7_JS" "$(node_path "$sf")" "$SID" 2>/dev/null)"
    if [ -z "$out" ]; then fail "T15_T18_sc7_variants: T15 unsurfaced expected non-empty stdout, got empty"; return; fi
    printf '{"alert":{"findings":[{"categories":["workflow"],"severity":"warning","detail":"t"}],"findings_surfaced_at":"2026-01-01T00:00:00Z"},"layer1":{"findings":[]},"audit":{"findings":[]}}\n' > "$sf"
    out="$(run_with_timeout 120 node "$SC7_JS" "$(node_path "$sf")" "$SID" 2>/dev/null)"
    if [ -z "$out" ]; then pass "T15_T18_sc7_variants: unsurfaced->non-empty, already-surfaced->empty"; else fail "T15_T18_sc7_variants: T18 already-surfaced expected empty stdout, got '$out'"; fi
}

# ============ Run all ============

test_T10_T11_no_args_exit1
test_T12_sc7_absent_path_empty
test_T13_detect_wf_meta_yes
test_T14_detect_wf_meta_no
test_T17_detect_no_state
test_T15_T18_sc7_variants

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
