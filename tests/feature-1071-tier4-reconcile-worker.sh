#!/bin/bash
# tests/feature-1071-tier4-reconcile-worker.sh
# Tests: bin/worker-dispatch/workers/issue-reconcile.js, hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/emit.js, agents/issue-create-survey-worker.md, skills/issue-create/SKILL.md, skills/issue-reconcile/SKILL.md
# Tags: static, agent, worker, worker-dispatch, issue-reconcile, issue-create, survey-worker, TL2, scope:issue-specific
#
# Tier 4 contract test for the reconcile worker and the issue-create survey worker
# (originally issue #1071).
# #1643 replaced the LLM subagent agents/issue-reconcile-worker.md with the plain
# script bin/worker-dispatch/workers/issue-reconcile.js, dispatched by
# skills/issue-reconcile/SKILL.md Step 2 through skills/_shared/worker-dispatch.md.
# Cases 1-3 therefore assert against the module, the renderer and the registry
# capability declaration. agents/issue-create-survey-worker.md is NOT part of that
# migration — it is still an LLM subagent, so cases 4-10 are unchanged.
#
# TL3 gap (what this test does NOT catch):
# - actual survey-worker verdict classification by the LLM (requires real claude -p)
# - a real reconcile scan over real GitHub issues (see tests/TL3-worker-dispatch-gh-contract.sh)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
RECONCILE_WORKER_JS="${AGENTS_DIR}/bin/worker-dispatch/workers/issue-reconcile.js"
REGISTRY_JS="${AGENTS_DIR}/hooks/lib/worker-dispatch-registry.js"
EMIT_JS="${AGENTS_DIR}/bin/worker-dispatch/emit.js"
SURVEY_WORKER_MD="${AGENTS_DIR}/agents/issue-create-survey-worker.md"
IC_MD="${AGENTS_DIR}/skills/issue-create/SKILL.md"
IR_MD="${AGENTS_DIR}/skills/issue-reconcile/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

frontmatter() {
    awk 'NR==1 && $0=="---"{infm=1; next} infm && $0=="---"{exit} infm{print}' "$1"
}

# ── Test 1: reconcile worker module exists ────────────────────────────────────
test_reconcile_worker_exists() {
    if [ -f "$RECONCILE_WORKER_JS" ]; then
        pass "1: bin/worker-dispatch/workers/issue-reconcile.js exists"
    else
        fail "1: bin/worker-dispatch/workers/issue-reconcile.js missing"
    fi
}

# ── Test 2: output contract (status triple + JSONL artifact of needs-reconcile) ─
test_reconcile_output_contract() {
    if [ ! -f "$RECONCILE_WORKER_JS" ] || [ ! -f "$REGISTRY_JS" ] || [ ! -f "$EMIT_JS" ]; then
        fail "2: reconcile worker, registry or emit module missing — cannot check output contract"
        return
    fi
    local out
    out=$(run_with_timeout 30 node -e '
      const reg = require(process.argv[1]);
      const emit = require(process.argv[2]);
      const entry = reg.workers["issue-reconcile"];
      if (!entry) { process.stdout.write("NO-ENTRY"); process.exit(0); }
      if (entry.renderer !== "status-triple") {
        process.stdout.write("RENDERER:" + entry.renderer); process.exit(0);
      }
      const text = emit.render(entry, {
        status: "complete",
        summary: "12 scanned; 3 to reconcile",
        artifactPath: "/tmp/x-issue-reconcile-worker.jsonl",
      });
      const lines = text.split("\n").filter((l) => l !== "");
      process.stdout.write(lines.map((l) => l.split(":")[0]).join(","));
    ' "$(nodepath "$REGISTRY_JS")" "$(nodepath "$EMIT_JS")" 2>&1)
    local jsonl_ok=0
    # The artifact is a JSONL worklist holding ONLY needs-reconcile rows.
    grep -q '\.jsonl' "$RECONCILE_WORKER_JS" && \
      grep -q 'classification !== "needs-reconcile"' "$RECONCILE_WORKER_JS" && jsonl_ok=1
    if [ "$out" = "status,summary,artifact_path" ] && [ "$jsonl_ok" -eq 1 ]; then
        pass "2: output contract is the status triple; artifact is a needs-reconcile JSONL"
    else
        fail "2: reconcile output contract incomplete" "keys='$out' jsonl_ok=$jsonl_ok"
    fi
}

# ── Test 3: reconcile worker is read-only (registry capability declaration) ───
# Read-only is now structural, not prose: bin/worker-dispatch/spawn.js only lets
# the worker run the binaries its registry entry declares, and fsguard.js only
# lets it write into its declared write scopes.
test_reconcile_worker_readonly() {
    if [ ! -f "$REGISTRY_JS" ]; then
        fail "3: registry missing — cannot check read-only constraint"
        return
    fi
    local caps
    caps=$(run_with_timeout 30 node -e '
      const reg = require(process.argv[1]);
      const e = reg.workers["issue-reconcile"];
      const ext = (e.binaries.external || []).slice().sort().join("|");
      const scripts = Object.keys(e.binaries.scripts || {}).sort().join("|");
      const scopes = (e.writeScopes || []).slice().sort().join("|");
      process.stdout.write(["ext=" + ext, "scripts=" + scripts, "scopes=" + scopes].join(" "));
    ' "$(nodepath "$REGISTRY_JS")" 2>&1)
    local has_comment=0
    grep -qE 'gh[^\n]*issue[^\n]*comment|issue", *"comment"' "$RECONCILE_WORKER_JS" && has_comment=1
    if [ "$caps" = "ext=gh scripts= scopes=plans-dir" ] && [ "$has_comment" -eq 0 ]; then
        pass "3: reconcile worker declares gh as its only binary and plans-dir as its only write scope"
    else
        fail "3: reconcile worker read-only constraint broken" "$caps has_comment=$has_comment"
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
