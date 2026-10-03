#!/bin/bash
# detect-sc7-tests.sh: bin/session-close-detect-wf-meta.js + bin/session-close-render-sc7.js
# Tests: bin/session-close-detect-wf-meta.js, bin/session-close-render-sc7.js
# Tags: scope:issue-specific, feature-2434, control-dir
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
    out="$(run_with_timeout 120 node "$SC7_JS" "$(ctl_path "$SID" supervisor-state.json)" "$SID" 2>/dev/null)"
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
    local sf out
    sf="$(ctl_path f1463-t15 supervisor-state.json)"; mkdir -p "${WF_DIR}/f1463-t15.control"
    printf '{"alert":{"findings":[{"categories":["workflow"],"severity":"warning","detail":"test"}],"findings_surfaced_at":null},"layer1":{"findings":[]},"audit":{"findings":[]}}\n' > "$sf"
    out="$(run_with_timeout 120 node "$SC7_JS" "$sf" f1463-t15 2>/dev/null)"
    if [ -z "$out" ]; then fail "T15_T18_sc7_variants: T15 unsurfaced expected non-empty stdout, got empty"; return; fi
    printf '{"alert":{"findings":[{"categories":["workflow"],"severity":"warning","detail":"t"}],"findings_surfaced_at":"2026-01-01T00:00:00Z"},"layer1":{"findings":[]},"audit":{"findings":[]}}\n' > "$sf"
    out="$(run_with_timeout 120 node "$SC7_JS" "$sf" f1463-t15 2>/dev/null)"
    if [ -z "$out" ]; then pass "T15_T18_sc7_variants: unsurfaced->non-empty, already-surfaced->empty"; else fail "T15_T18_sc7_variants: T18 already-surfaced expected empty stdout, got '$out'"; fi
}

# ============ T22-T27: #2434 sc7 derives supervisor-state from --session ============

SC7_UNSURFACED='{"alert":{"findings":[{"categories":["workflow"],"severity":"warning","detail":"d2434"}],"findings_surfaced_at":null},"layer1":{"findings":[]},"audit":{"findings":[]}}'
SC7_RC=0; SC7_OUT=""
sc7_run() {  # argv... -> SC7_RC / SC7_OUT
    SC7_RC=0
    SC7_OUT="$(run_with_timeout 120 node "$SC7_JS" "$@" 2>/dev/null)" || SC7_RC=$?
}
seed_sc7_state() {  # <sid>: unsurfaced findings at the derived control path
    mkdir -p "${WF_DIR}/$1.control"
    printf '%s\n' "$SC7_UNSURFACED" > "$(ctl_path "$1" supervisor-state.json)"
}

test_T22_T23_sc7_session_form() {
    if [ ! -f "$SC7_JS" ]; then skip "T22+T23 (bin/session-close-render-sc7.js missing)"; return; fi
    seed_sc7_state f1463-s22
    sc7_run --session f1463-s22
    if [ "$SC7_RC" = "0" ] && [ -n "$SC7_OUT" ]; then pass "T22: --session reads the derived supervisor-state"
    else fail "T22: --session expected exit 0 + non-empty stdout, got exit $SC7_RC, out='$SC7_OUT'"; fi
    sc7_run --session f1463-s23-absent
    if [ "$SC7_RC" = "0" ] && [ -z "$SC7_OUT" ]; then pass "T23: --session with absent state -> exit 0, empty"
    else fail "T23: expected exit 0 + empty, got exit $SC7_RC, out='$SC7_OUT'"; fi
}

test_T24_sc7_session_migrates_plans_state() {
    if [ ! -f "$SC7_JS" ]; then skip "T24 (bin/session-close-render-sc7.js missing)"; return; fi
    printf '%s\n' "$SC7_UNSURFACED" > "${PLANS_DIR}/f1463-s24-supervisor-state.json"
    sc7_run --session f1463-s24
    if [ "$SC7_RC" = "0" ] && [ -n "$SC7_OUT" ] && [ -f "$(ctl_path f1463-s24 supervisor-state.json)" ]; then
        pass "T24: legacy PLANS supervisor-state migrated and rendered"
    else
        fail "T24: expected exit 0 + non-empty + derived file, got exit $SC7_RC, out='$SC7_OUT'"
    fi
}

test_T25_sc7_legacy_derived_positional() {
    if [ ! -f "$SC7_JS" ]; then skip "T25 (bin/session-close-render-sc7.js missing)"; return; fi
    seed_sc7_state f1463-s25
    sc7_run "$(ctl_path f1463-s25 supervisor-state.json)" f1463-s25
    if [ "$SC7_RC" = "0" ] && [ -n "$SC7_OUT" ]; then pass "T25: legacy derived positional accepted"
    else fail "T25: expected exit 0 + non-empty, got exit $SC7_RC"; fi
}

test_T26_sc7_rejected_positionals() {
    if [ ! -f "$SC7_JS" ]; then skip "T26 (bin/session-close-render-sc7.js missing)"; return; fi
    seed_sc7_state f1463-s26-other
    printf '%s\n' "$SC7_UNSURFACED" > "${TMPDIR_BASE}/sc7-arbitrary.json"
    local label p
    while IFS='|' read -r label p; do
        [ -n "$label" ] || continue
        sc7_run "$p" f1463-s26
        if [ "$SC7_RC" != "0" ] && [ -z "$SC7_OUT" ]; then pass "T26: rejected legacy state path ($label)"
        else fail "T26: rejected legacy state path ($label) -- got exit $SC7_RC, out='$SC7_OUT'"; fi
    done <<EOF
other-sid-control|$(ctl_path f1463-s26-other supervisor-state.json)
arbitrary-path|$(node_path "${TMPDIR_BASE}/sc7-arbitrary.json")
EOF
}

test_T27_sc7_invalid_sid() {
    if [ ! -f "$SC7_JS" ]; then skip "T27 (bin/session-close-render-sc7.js missing)"; return; fi
    local label sid
    while IFS='|' read -r label sid; do
        [ -n "$label" ] || continue
        if [ "$sid" = "@MISSING@" ]; then sc7_run --session; else sc7_run --session "$sid"; fi
        if [ "$SC7_RC" != "0" ] && [ -z "$SC7_OUT" ]; then pass "T27: invalid sid rejected ($label)"
        else fail "T27: invalid sid rejected ($label) -- got exit $SC7_RC"; fi
    done <<'EOF'
traversal|../f1463-s22
space|a b
empty|
missing|@MISSING@
EOF
    local line
    line="$(grep -F 'session-close-render-sc7.js' "$SKILL_MD" | head -1)"
    if printf '%s' "$line" | grep -qF -- '--session' && ! printf '%s' "$line" | grep -qF '<CONTROL_DIR>/'; then
        pass "T27: SKILL sc7 call passes --session and no control path"
    else
        fail "T27: SKILL sc7 call still passes a control path: $line"
    fi
}

# ============ Run all ============

test_T10_T11_no_args_exit1
test_T12_sc7_absent_path_empty
test_T13_detect_wf_meta_yes
test_T14_detect_wf_meta_no
test_T17_detect_no_state
test_T15_T18_sc7_variants
test_T22_T23_sc7_session_form
test_T24_sc7_session_migrates_plans_state
test_T25_sc7_legacy_derived_positional
test_T26_sc7_rejected_positionals
test_T27_sc7_invalid_sid

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
