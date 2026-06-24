#!/bin/bash
# tests/feature-1071-tier4-reconcile-worker.sh
# Tests: agents/issue-reconcile-worker.md, agents/issue-create-survey-worker.md, skills/issue-create/SKILL.md, skills/issue-reconcile/SKILL.md
# Tags: static, agent, worker, issue-reconcile, issue-create, survey-worker, scope:issue-specific
#
# Tier 4 static contract test for issue #1071 (skill/agent fork+worker audit).
# Verifies the new reconcile-worker and survey-worker agents, plus Phase 3
# confirmation semantics in issue-create SKILL.md.
# Expected RED until #1071 creates the two worker .md files and updates
# skills/issue-reconcile/SKILL.md with user-invocable: false.
#
# L3 gap (what this test does NOT catch):
# - actual survey-worker verdict classification by the LLM (requires real claude -p)
# - runtime reconcile scan over real GitHub issues
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECONCILE_WORKER_MD="${AGENTS_DIR}/agents/issue-reconcile-worker.md"
SURVEY_WORKER_MD="${AGENTS_DIR}/agents/issue-create-survey-worker.md"
IC_MD="${AGENTS_DIR}/skills/issue-create/SKILL.md"
IR_MD="${AGENTS_DIR}/skills/issue-reconcile/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

frontmatter() {
    awk 'NR==1 && $0=="---"{infm=1; next} infm && $0=="---"{exit} infm{print}' "$1"
}

# ── Test 1: issue-reconcile-worker.md exists ──────────────────────────────────
test_reconcile_worker_exists() {
    if [ -f "$RECONCILE_WORKER_MD" ]; then
        pass "1: agents/issue-reconcile-worker.md exists"
    else
        fail "1: agents/issue-reconcile-worker.md missing"
    fi
}

# ── Test 2: reconcile-worker output contract (3 lines + JSONL artifact) ───────
test_reconcile_output_contract() {
    if [ ! -f "$RECONCILE_WORKER_MD" ]; then
        fail "2: reconcile-worker missing — cannot check output contract"
        return
    fi
    local has_status has_summary has_artifact
    has_status=0; has_summary=0; has_artifact=0
    grep -qE '^status:' "$RECONCILE_WORKER_MD" && has_status=1
    grep -qE '^summary:' "$RECONCILE_WORKER_MD" && has_summary=1
    grep -qE '^artifact_path:' "$RECONCILE_WORKER_MD" && has_artifact=1
    if [ "$has_status" -eq 1 ] && [ "$has_summary" -eq 1 ] && [ "$has_artifact" -eq 1 ]; then
        pass "2: reconcile-worker output contract has status:/summary:/artifact_path:"
    else
        fail "2: reconcile-worker output contract incomplete" "status=$has_status summary=$has_summary artifact_path=$has_artifact"
    fi
}

# ── Test 3: reconcile-worker is read-only (no gh issue comment, no doc-append) ─
test_reconcile_worker_readonly() {
    if [ ! -f "$RECONCILE_WORKER_MD" ]; then
        fail "3: reconcile-worker missing — cannot check read-only constraint"
        return
    fi
    local has_comment has_docappend
    has_comment=0; has_docappend=0
    grep -qE 'gh issue comment' "$RECONCILE_WORKER_MD" && has_comment=1
    grep -qE 'doc-append' "$RECONCILE_WORKER_MD" && has_docappend=1
    if [ "$has_comment" -eq 0 ] && [ "$has_docappend" -eq 0 ]; then
        pass "3: reconcile-worker is read-only (no gh issue comment or doc-append)"
    else
        fail "3: reconcile-worker contains write operations" "comment=$has_comment docappend=$has_docappend"
    fi
}

# ── Test 4: issue-create-survey-worker.md exists ─────────────────────────────
test_survey_worker_exists() {
    if [ -f "$SURVEY_WORKER_MD" ]; then
        pass "4: agents/issue-create-survey-worker.md exists"
    else
        fail "4: agents/issue-create-survey-worker.md missing"
    fi
}

# ── Test 5: survey-worker verdict JSON schema has all 4 fields ───────────────
test_survey_verdict_schema() {
    if [ ! -f "$SURVEY_WORKER_MD" ]; then
        fail "5: survey-worker missing — cannot check verdict schema"
        return
    fi
    local fields="verdict target reason candidates"
    local missing=""
    for field in $fields; do
        if ! grep -qF "$field" "$SURVEY_WORKER_MD"; then
            missing="$missing $field"
        fi
    done
    if [ -z "$missing" ]; then
        pass "5: survey-worker verdict JSON schema has all 4 fields (verdict/target/reason/candidates)"
    else
        fail "5: survey-worker verdict schema missing fields:$missing"
    fi
}

# ── Test 6: survey-worker documents no_candidates status ──────────────────────
test_survey_no_candidates() {
    if [ ! -f "$SURVEY_WORKER_MD" ]; then
        fail "6: survey-worker missing — cannot check no_candidates"
        return
    fi
    if grep -qF 'no_candidates' "$SURVEY_WORKER_MD"; then
        pass "6: survey-worker documents no_candidates status"
    else
        fail "6: survey-worker missing no_candidates status documentation"
    fi
}

# ── Test 7: survey-worker has no AskUserQuestion ─────────────────────────────
test_survey_worker_no_ask() {
    if [ ! -f "$SURVEY_WORKER_MD" ]; then
        fail "7: survey-worker missing — cannot check AskUserQuestion"
        return
    fi
    if grep -qF 'AskUserQuestion' "$SURVEY_WORKER_MD"; then
        fail "7: survey-worker contains AskUserQuestion (Phase 3 confirm must stay in main context)"
    else
        pass "7: survey-worker has no AskUserQuestion (confirm stays in main)"
    fi
}

# ── Test 8: issue-create SKILL.md Phase 3 confirms for reopen and make-parent ─
test_ic_phase3_confirm_reopen_makeparent() {
    if [ ! -f "$IC_MD" ]; then
        fail "8: skills/issue-create/SKILL.md missing"
        return
    fi
    local has_reopen_confirm has_makeparent_confirm
    has_reopen_confirm=0; has_makeparent_confirm=0
    grep -qE 'reopen.*(Confirm|AskUserQuestion|required)|AskUserQuestion.*reopen' "$IC_MD" && has_reopen_confirm=1
    grep -qE 'make-parent.*(Confirm|AskUserQuestion|required)|AskUserQuestion.*make.parent' "$IC_MD" && has_makeparent_confirm=1
    if [ "$has_reopen_confirm" -eq 1 ] && [ "$has_makeparent_confirm" -eq 1 ]; then
        pass "8: issue-create Phase 3 requires confirm for reopen and make-parent"
    else
        fail "8: issue-create Phase 3 missing confirms" "reopen=$has_reopen_confirm make-parent=$has_makeparent_confirm"
    fi
}

# ── Test 9: issue-create SKILL.md Phase 3 proceeds without confirm for none/sub-of/sibling ─
test_ic_phase3_no_confirm_others() {
    if [ ! -f "$IC_MD" ]; then
        fail "9: skills/issue-create/SKILL.md missing"
        return
    fi
    # The skill must document that none/sub-of/sibling proceed without confirmation
    if grep -qE 'sub-of.*(without|no).*(confirm|Confirm)|sibling.*(without|no).*(confirm|Confirm)|none.*(without|no).*(confirm|Confirm)' "$IC_MD" || \
       grep -qE '(without|no).*(confirm|Confirm).*(sub-of|sibling|none)' "$IC_MD"; then
        pass "9: issue-create Phase 3 documents no-confirm for none/sub-of/sibling"
    else
        fail "9: issue-create Phase 3 missing no-confirm documentation for none/sub-of/sibling"
    fi
}

# ── Test 10: issue-reconcile SKILL.md has user-invocable: false ───────────────
test_ir_user_invocable_false() {
    if [ ! -f "$IR_MD" ]; then
        fail "10: skills/issue-reconcile/SKILL.md missing"
        return
    fi
    if frontmatter "$IR_MD" | grep -qE '^user-invocable:[[:space:]]*false[[:space:]]*$'; then
        pass "10: skills/issue-reconcile/SKILL.md has user-invocable: false"
    else
        fail "10: skills/issue-reconcile/SKILL.md missing 'user-invocable: false' in frontmatter"
    fi
}

test_reconcile_worker_exists
test_reconcile_output_contract
test_reconcile_worker_readonly
test_survey_worker_exists
test_survey_verdict_schema
test_survey_no_candidates
test_survey_worker_no_ask
test_ic_phase3_confirm_reopen_makeparent
test_ic_phase3_no_confirm_others
test_ir_user_invocable_false

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
