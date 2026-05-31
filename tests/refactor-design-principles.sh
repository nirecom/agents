#!/bin/bash
# tests/refactor-design-principles.sh
# Tests: agents/detail-reviewer.md, agents/outline-reviewer.md, hooks/workflow-mark.js, skills/make-detail-plan/SKILL.md, skills/survey-code/SKILL.md
# Tags: design-principles
#
# Integration tests for the refactor/design-principles branch.
#
# Section A: USER_VERIFIED sentinel — soft warnings + state recording
# Section B: Static checks — rules/core-principles.md,
#            skills/make-detail-plan/SKILL.md, skills/survey-code/SKILL.md

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MARK_JS="${_AGENTS_DIR_NODE}/hooks/workflow-mark.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'rdp-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Portable timeout: prefers `timeout`, falls back to perl alarm (macOS-safe).
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_mark_js() {
    if [ ! -f "$MARK_JS" ]; then
        fail "$1 (workflow-mark.js not present)"
        return 1
    fi
    return 0
}

# Allocate a fresh per-test workflow dir (so state files don't leak across tests).
fresh_workflow_dir() {
    local d="$TMPDIR_BASE/wf-$RANDOM-$$"
    mkdir -p "$d"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$d"
    else
        echo "$d"
    fi
}

# JSON-safely pack a string as a JSON-encoded literal (via node).
json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

# Build a PostToolUse Bash payload for workflow-mark.js.
# Args: session-id command-string exit-code
build_mark_payload() {
    local sid="$1" cmd="$2" rc="$3"
    local q_sid q_cmd
    q_sid="$(json_quote "$sid")"
    q_cmd="$(json_quote "$cmd")"
    printf '{"session_id":%s,"tool_name":"Bash","tool_input":{"command":%s},"tool_response":{"exit_code":%s,"stdout":"","stderr":""}}' \
        "$q_sid" "$q_cmd" "$rc"
}

# Same but with session_id omitted entirely.
build_mark_payload_no_sid() {
    local cmd="$1" rc="$2"
    local q_cmd
    q_cmd="$(json_quote "$cmd")"
    printf '{"tool_name":"Bash","tool_input":{"command":%s},"tool_response":{"exit_code":%s,"stdout":"","stderr":""}}' \
        "$q_cmd" "$rc"
}

MARK_OUT=""
# run_workflow_mark <stdin-json> <workflow-dir>
# Captures stdout+stderr into MARK_OUT.
run_workflow_mark() {
    local payload="$1" wfdir="$2"
    local rc=0
    MARK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        node "$MARK_JS" 2>&1)" || rc=$?
    return $rc
}

# Read user_verification status from state JSON file.
# Usage: read_uv_status <wfdir> <sid>  → echoes status string or empty
read_uv_status() {
    local wfdir="$1" sid="$2"
    local sf="$wfdir/$sid.json"
    [ -f "$sf" ] || { echo ""; return; }
    node -e "
try {
  const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
  console.log((s.steps&&s.steps.user_verification&&s.steps.user_verification.status)||'');
} catch(e) { console.log(''); }
" "$sf" 2>/dev/null || echo ""
}

# ============================================================================
# A. USER_VERIFIED sentinel
# ============================================================================

test_A1_bare_user_verified_rejected_as_malformed() {
    require_mark_js "A1" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession1"
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_USER_VERIFIED>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"

    # Bare form must be rejected — user_verification must remain pending (NOT complete)
    local status; status="$(read_uv_status "$wfdir" "$sid")"
    if [ "$status" = "complete" ]; then
        fail "A1: bare USER_VERIFIED was accepted (status=complete, expected pending) (out: $MARK_OUT)"
        return
    fi

    # Must emit a "malformed USER_VERIFIED" error (case-insensitive)
    if ! echo "$MARK_OUT" | grep -qi "malformed USER_VERIFIED"; then
        fail "A1: expected 'malformed USER_VERIFIED' in output (out: $MARK_OUT)"
        return
    fi

    pass "A1: bare USER_VERIFIED rejected as malformed — status remains pending"
}

test_A2_valid_reason_records_without_warn() {
    require_mark_js "A2" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession2"
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_USER_VERIFIED: merging PR 12>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"

    # user_verification must be recorded as complete
    local status; status="$(read_uv_status "$wfdir" "$sid")"
    if [ "$status" != "complete" ]; then
        fail "A2: user_verification not recorded as complete (status='$status', out: $MARK_OUT)"
        return
    fi

    # Must NOT emit the "without reason" warning
    if echo "$MARK_OUT" | grep -q "emitted without reason"; then
        fail "A2: unexpected 'emitted without reason' warning for valid reason (out: $MARK_OUT)"
        return
    fi

    # Must NOT emit "reason rejected"
    if echo "$MARK_OUT" | grep -q "reason rejected"; then
        fail "A2: unexpected 'reason rejected' for valid reason (out: $MARK_OUT)"
        return
    fi

    pass "A2: valid reason USER_VERIFIED — recorded as complete, no warnings"
}

test_A3_short_reason_records_and_warns() {
    require_mark_js "A3" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession3"
    # "no" is only 2 non-space chars — too short
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_USER_VERIFIED: no>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"

    # user_verification must STILL be recorded despite bad reason
    local status; status="$(read_uv_status "$wfdir" "$sid")"
    if [ "$status" != "complete" ]; then
        fail "A3: user_verification not recorded as complete despite bad reason (status='$status', out: $MARK_OUT)"
        return
    fi

    # Must emit "reason rejected"
    if ! echo "$MARK_OUT" | grep -q "USER_VERIFIED reason rejected"; then
        fail "A3: expected 'USER_VERIFIED reason rejected' in output (out: $MARK_OUT)"
        return
    fi

    pass "A3: too-short reason — warn but apply (soft-validation tradeoff) + reason-rejected warning"
}

test_A4_no_session_id_not_recorded() {
    require_mark_js "A4" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local payload; payload="$(build_mark_payload_no_sid 'echo "<<WORKFLOW_USER_VERIFIED: no session id branch>>"' 0)"
    local rc=0
    # No CLAUDE_ENV_FILE → no session ID resolvable
    MARK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        node "$MARK_JS" 2>&1)" || rc=$?

    # Must not crash
    if [ "$rc" -ne 0 ]; then
        fail "A4: workflow-mark.js crashed with rc=$rc (out: $MARK_OUT)"
        return
    fi

    # No state file should be written (or if written, user_verification not complete)
    local json_count
    json_count="$(ls -1 "$wfdir" 2>/dev/null | grep -c '\.json$' || true)"
    if [ "$json_count" -ne 0 ]; then
        # A state file may exist from other operations but user_verification must not be complete
        # Check if any .json file has user_verification=complete
        local any_complete=0
        for f in "$wfdir"/*.json; do
            [ -f "$f" ] || continue
            local s; s="$(node -e "
try {
  const st=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
  console.log((st.steps&&st.steps.user_verification&&st.steps.user_verification.status)||'');
} catch(e){console.log('');}
" "$f" 2>/dev/null)"
            if [ "$s" = "complete" ]; then
                any_complete=1
                break
            fi
        done
        if [ "$any_complete" -eq 1 ]; then
            fail "A4: user_verification recorded as complete without session_id (out: $MARK_OUT)"
            return
        fi
    fi

    # Must emit "could not resolve session_id"
    if ! echo "$MARK_OUT" | grep -q "could not resolve session_id"; then
        fail "A4: expected 'could not resolve session_id' in output (out: $MARK_OUT)"
        return
    fi

    pass "A4: no session_id — user_verification NOT recorded, session_id warning emitted"
}

# ============================================================================
# B. Static checks
# ============================================================================

test_B1_core_principles_exists() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ -f "$f" ]; then
        pass "B1: rules/core-principles.md exists"
    else
        fail "B1: rules/core-principles.md NOT found"
    fi
}

test_B2_elevate_perspective_header() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B2: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qF "## 2. Elevate Perspective" "$f"; then
        pass "B2: '## 2. Elevate Perspective' header present"
    else
        fail "B2: '## 2. Elevate Perspective' header NOT found in rules/core-principles.md"
    fi
}

test_B3_orthogonality_header() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B3: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qF "## 3. Orthogonality" "$f"; then
        pass "B3: '## 3. Orthogonality' header present"
    else
        fail "B3: '## 3. Orthogonality' header NOT found in rules/core-principles.md"
    fi
}

test_B4_name_reflects_substance_header() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B4: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qF "## 6. Name Reflects Substance" "$f"; then
        pass "B4: '## 6. Name Reflects Substance' header present"
    else
        fail "B4: '## 6. Name Reflects Substance' header NOT found in rules/core-principles.md"
    fi
}

test_B5_orthogonality_md_removed() {
    local f="$AGENTS_DIR/rules/orthogonality.md"
    if [ ! -f "$f" ]; then
        pass "B5: rules/orthogonality.md does not exist (correctly removed)"
    else
        fail "B5: rules/orthogonality.md still exists (should have been removed)"
    fi
}

test_B6_make_detail_plan_references_core_principles() {
    local f="$AGENTS_DIR/skills/make-detail-plan/SKILL.md"
    if [ ! -f "$f" ]; then
        fail "B6: skills/make-detail-plan/SKILL.md not found"
        return
    fi
    if grep -qF "rules/core-principles.md" "$f"; then
        pass "B6: skills/make-detail-plan/SKILL.md references rules/core-principles.md"
    else
        fail "B6: skills/make-detail-plan/SKILL.md does NOT reference rules/core-principles.md"
    fi
}

test_B7_survey_code_references_core_principles() {
    local f="$AGENTS_DIR/skills/survey-code/SKILL.md"
    if [ ! -f "$f" ]; then
        fail "B7: skills/survey-code/SKILL.md not found"
        return
    fi
    if grep -qF "rules/core-principles.md" "$f"; then
        pass "B7: skills/survey-code/SKILL.md references rules/core-principles.md"
    else
        fail "B7: skills/survey-code/SKILL.md does NOT reference rules/core-principles.md"
    fi
}

test_B8_no_residual_plan_principles_references() {
    local hits
    hits=$(cd "$AGENTS_DIR" && git ls-files -z \
           | xargs -0 grep -l 'plan-principles' 2>/dev/null \
           | grep -v '^docs/history' \
           | grep -v '^tests/' || true)
    if [ -z "$hits" ]; then
        pass "B8: no residual 'plan-principles' references in tracked canonical files"
    else
        fail "B8: residual 'plan-principles' references found in: $hits"
    fi
}

test_B9_ssot_section_header() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B9: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qF "## 1. Single Source of Truth" "$f"; then
        pass "B9: '## 1. Single Source of Truth' header present"
    else
        fail "B9: '## 1. Single Source of Truth' header NOT found"
    fi
}

test_B10_elevate_perspective_per_class_wording() {
    local f="$AGENTS_DIR/rules/core-principles.md"
    if [ ! -f "$f" ]; then
        fail "B10: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qF "merged, replaced, or restructured" "$f"; then
        pass "B10: §2 contains class-level alternative wording"
    else
        fail "B10: §2 does NOT contain class-level alternative wording"
    fi
}

test_B11_outline_reviewer_references_core_principles() {
    local f="$AGENTS_DIR/agents/outline-reviewer.md"
    if [ ! -f "$f" ]; then
        fail "B11: agents/outline-reviewer.md not found"
        return
    fi
    if grep -qF "rules/core-principles.md" "$f"; then
        pass "B11: agents/outline-reviewer.md references rules/core-principles.md"
    else
        fail "B11: agents/outline-reviewer.md does NOT reference rules/core-principles.md"
    fi
}

test_B12_detail_reviewer_references_core_principles() {
    local f="$AGENTS_DIR/agents/detail-reviewer.md"
    if [ ! -f "$f" ]; then
        fail "B12: agents/detail-reviewer.md not found"
        return
    fi
    if grep -qF "rules/core-principles.md" "$f"; then
        pass "B12: agents/detail-reviewer.md references rules/core-principles.md"
    else
        fail "B12: agents/detail-reviewer.md does NOT reference rules/core-principles.md"
    fi
}

test_B13_plan_principles_old_path_removed() {
    local f="$AGENTS_DIR/rules/plan-principles.md"
    if [ ! -f "$f" ]; then
        pass "B13: rules/plan-principles.md does not exist (correctly renamed)"
    else
        fail "B13: rules/plan-principles.md still exists (should have been renamed)"
    fi
}

# ============================================================================
# Run all (wrap in 120s wall-clock timeout if available)
# ============================================================================

run_all() {
    # A: USER_VERIFIED sentinel
    test_A1_bare_user_verified_rejected_as_malformed
    test_A2_valid_reason_records_without_warn
    test_A3_short_reason_records_and_warns
    test_A4_no_session_id_not_recorded
    # B: static checks
    test_B1_core_principles_exists
    test_B2_elevate_perspective_header
    test_B3_orthogonality_header
    test_B4_name_reflects_substance_header
    test_B5_orthogonality_md_removed
    test_B6_make_detail_plan_references_core_principles
    test_B7_survey_code_references_core_principles
    test_B8_no_residual_plan_principles_references
    test_B9_ssot_section_header
    test_B10_elevate_perspective_per_class_wording
    test_B11_outline_reviewer_references_core_principles
    test_B12_detail_reviewer_references_core_principles
    test_B13_plan_principles_old_path_removed
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_DESIGN_PRINCIPLES_TEST_INNER:-}" ]; then
        _DESIGN_PRINCIPLES_TEST_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
