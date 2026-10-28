#!/bin/bash
# tests/bin/feature-1071-tier4-reconcile-worker.sh
# Tests: bin/worker-dispatch/workers/issue-reconcile.js, hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/emit.js, agents/issue-create-survey-worker.md, skills/issue-create/SKILL.md, skills/issue-reconcile/SKILL.md
# Tags: static, agent, worker, worker-dispatch, issue-reconcile, issue-create, survey-worker, TL2, scope:issue-specific
# Tier 4 (#1071): cases 1-3 pin the issue-reconcile script worker (#1643); cases 4-10
# pin the still-LLM issue-create survey worker.
# TL3 gap: LLM verdict classification and a real gh scan (TL3-worker-dispatch-gh-contract.sh).
# Mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
RECONCILE_WORKER_JS="${SCRIPT_CHECKOUT_ROOT}/bin/worker-dispatch/workers/issue-reconcile.js"
REGISTRY_JS="${SCRIPT_CHECKOUT_ROOT}/hooks/lib/worker-dispatch-registry.js"
EMIT_JS="${SCRIPT_CHECKOUT_ROOT}/bin/worker-dispatch/emit.js"
SURVEY_WORKER_MD="${SCRIPT_CHECKOUT_ROOT}/agents/issue-create-survey-worker.md"
IC_MD="${SCRIPT_CHECKOUT_ROOT}/skills/issue-create/SKILL.md"
IR_MD="${SCRIPT_CHECKOUT_ROOT}/skills/issue-reconcile/SKILL.md"

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
    # #2558: the .jsonl artifact stays in plans-dir; the worker log moved to log-dir.
    if [ "$caps" = "ext=gh scripts= scopes=log-dir|plans-dir" ] && [ "$has_comment" -eq 0 ]; then
        pass "3: reconcile worker declares gh as its only binary and plans-dir + log-dir as its write scopes"
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
    # Since #1763 the reopen/make-parent requirement is one of four OR-ed gate
    # conditions (G1), documented as a bullet naming both verdicts. The guarantee is
    # unchanged — those two verdicts always confirm — but it is no longer stated on a
    # line that also carries the word "Confirm", so match the condition itself.
    local has_g1_reopen has_g1_makeparent
    has_g1_reopen=0; has_g1_makeparent=0
    grep -qE '^- G1 .*reopen' "$IC_MD" && has_g1_reopen=1
    grep -qE '^- G1 .*make-parent' "$IC_MD" && has_g1_makeparent=1
    if [ "$has_g1_reopen" -eq 1 ] && [ "$has_g1_makeparent" -eq 1 ]; then
        pass "8: issue-create Phase 3 gate condition G1 covers reopen and make-parent"
    else
        fail "8: issue-create Phase 3 G1 does not cover both verdicts" "reopen=$has_g1_reopen make-parent=$has_g1_makeparent"
    fi
}

# ── Test 9: issue-create SKILL.md Phase 3 documents the full confirm gate ────
test_ic_phase3_gate_conditions_documented() {
    if [ ! -f "$IC_MD" ]; then
        fail "9: skills/issue-create/SKILL.md missing"
        return
    fi
    # This test previously asserted that none/sub-of/sibling proceed WITHOUT
    # confirmation. #1763 deliberately withdrew that guarantee: the gate is now an OR
    # of four conditions, and G3 (mid-workflow provenance below severity:high) and G4
    # (unverified verdict) can fire on any verdict. Asserting the old blanket
    # exemption would now pin a contract the skill intentionally no longer offers.
    # What must be documented instead is the complete condition set plus the single
    # script that owns the decision, so no caller re-derives the gate by hand.
    local missing=""
    for g in G1 G2 G3 G4; do
        grep -qE "^- $g " "$IC_MD" || missing="$missing $g"
    done
    if [ -n "$missing" ]; then
        fail "9: issue-create Phase 3 gate conditions incomplete" "missing:$missing"
    elif ! grep -q 'eval-confirm-gate.sh' "$IC_MD"; then
        fail "9: issue-create Phase 3 does not delegate the gate decision to eval-confirm-gate.sh"
    else
        pass "9: issue-create Phase 3 documents gate conditions G1-G4 and delegates to eval-confirm-gate.sh"
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

# ── Tests 11-12 (#2731): issue writers take the terminology rule, never a language ─
# The reference names the TERMS line of hooks/lib/lang-directives.txt plus the glossary
# Writer directives; it never names the CONV_LANG line (that would impose a body language).
LANG_DIRECTIVES_TXT="${SCRIPT_CHECKOUT_ROOT}/hooks/lib/lang-directives.txt"

# directive_text <file> — the text the writer is told: frontmatter and HTML comments blanked,
# line numbers kept, so a mention that only sits in metadata or a comment never counts.
directive_text() {
    awk '
        NR == 1 && $0 == "---" { infm = 1; print ""; next }
        infm { if ($0 == "---") infm = 0; print ""; next }
        {
            rest = $0; out = ""
            while (rest != "") {
                if (incom) {
                    i = index(rest, "-->"); if (i == 0) { rest = ""; break }
                    rest = substr(rest, i + 3); incom = 0
                } else {
                    i = index(rest, "<!--"); if (i == 0) { out = out rest; rest = ""; break }
                    out = out substr(rest, 1, i - 1); rest = substr(rest, i + 4); incom = 1
                }
            }
            print out
        }' "$1"
}

# terms_reference_problems <file> — prints the problems found; empty means the reference is right.
terms_reference_problems() {
    local text ref_lines problems=""
    text="$(directive_text "$1")"
    ref_lines="$(printf '%s\n' "$text" | grep -F 'lang-directives.txt' || true)"
    [ -n "$ref_lines" ] || problems="$problems [no lang-directives.txt reference in the directive text]"
    if [ -n "$ref_lines" ] && ! printf '%s\n' "$ref_lines" | grep -qF 'TERMS'; then
        problems="$problems [lang-directives.txt reference does not name the TERMS line]"
    fi
    if printf '%s\n' "$ref_lines" | grep -qE 'CONV_LANG|PLAN_LANG'; then
        problems="$problems [lang-directives.txt reference names a language-bearing line]"
    fi
    printf '%s\n' "$text" | grep -qF 'combined-glossary.md' || problems="$problems [no combined-glossary.md reference in the directive text]"
    printf '%s' "$problems"
}

check_terms_reference() {
    local id="$1" file="$2" label="$3"
    if [ ! -f "$file" ]; then
        fail "$id: $label missing"
        return
    fi
    local problems
    problems="$(terms_reference_problems "$file")"
    if [ -z "$problems" ]; then
        pass "$id: $label applies the TERMS line and combined-glossary, not the CONV_LANG line"
    else
        fail "$id: $label terminology reference wrong" "$problems"
    fi
}

test_ic_terms_reference() {
    check_terms_reference "11" "$IC_MD" "skills/issue-create/SKILL.md"
}

test_survey_worker_terms_reference() {
    check_terms_reference "12" "$SURVEY_WORKER_MD" "agents/issue-create-survey-worker.md"
    # The worker's reference is a Rule line (free-text `reason`), placed under ## Rules.
    local rules_ln ref_ln out_ln
    rules_ln="$(grep -n '^## Rules' "$SURVEY_WORKER_MD" 2>/dev/null | head -n 1 | cut -d: -f1)"
    out_ln="$(grep -n '^## Output contract' "$SURVEY_WORKER_MD" 2>/dev/null | head -n 1 | cut -d: -f1)"
    ref_ln="$( [ -f "$SURVEY_WORKER_MD" ] && directive_text "$SURVEY_WORKER_MD" | grep -nF 'lang-directives.txt' | head -n 1 | cut -d: -f1)"
    if [ -n "$rules_ln" ] && [ -n "$out_ln" ] && [ -n "$ref_ln" ] && [ "$rules_ln" -lt "$ref_ln" ] && [ "$ref_ln" -lt "$out_ln" ]; then
        pass "12b: survey-worker TERMS reference sits under ## Rules"
    else
        fail "12b: survey-worker TERMS reference not under ## Rules" "rules=${rules_ln:-none} ref=${ref_ln:-none} output=${out_ln:-none}"
    fi
}

# ── Test 13 (#2731): the TERMS line carries no {lang} — it never imposes a language ─
test_terms_line_language_free() {
    if [ ! -f "$LANG_DIRECTIVES_TXT" ]; then
        fail "13: hooks/lib/lang-directives.txt missing"
        return
    fi
    local terms_lines terms
    terms_lines="$(grep -c '^TERMS=' "$LANG_DIRECTIVES_TXT" || true)"
    terms="$(grep '^TERMS=' "$LANG_DIRECTIVES_TXT" | head -n 1)"
    if [ "$terms_lines" != "1" ]; then
        fail "13: lang-directives.txt must hold exactly one TERMS= line" "count=$terms_lines"
    elif [ "$terms" = "TERMS=" ]; then
        fail "13: TERMS line is empty"
    elif printf '%s' "$terms" | grep -qF '{lang}'; then
        fail "13: TERMS line contains {lang}" "$terms"
    else
        pass "13: TERMS line is non-empty and carries no {lang}"
    fi
}

# ── Test 14 (#2731): the TERMS check rejects a mention that sits only in metadata or a comment ─
test_terms_reference_ignores_comments() {
    local tmp_dir ref
    tmp_dir="$(mktemp -d)"
    ref='Apply the TERMS line of hooks/lib/lang-directives.txt and the Writer directives in skills/_shared/combined-glossary.md to issue titles and bodies.'
    printf -- '---\ndescription: %s\n---\n\n# Skill\n<!-- %s -->\nBody.\n<!--\n%s\n-->\n' "$ref" "$ref" "$ref" > "$tmp_dir/comment-only.md"
    printf -- '---\nname: x\n---\n\n# Skill\n%s\n' "$ref" > "$tmp_dir/directive.md"
    local comment_problems directive_problems
    comment_problems="$(terms_reference_problems "$tmp_dir/comment-only.md")"
    directive_problems="$(terms_reference_problems "$tmp_dir/directive.md")"
    rm -rf "$tmp_dir"
    if [ -z "$comment_problems" ]; then
        fail "14: a frontmatter / HTML-comment-only TERMS mention passed the check"
    elif [ -n "$directive_problems" ]; then
        fail "14: control — the same sentence as a directive line was rejected" "$directive_problems"
    else
        pass "14: comment-only TERMS mention fails the check; the same sentence as a directive passes"
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
test_ic_phase3_gate_conditions_documented
test_ir_user_invocable_false
test_ic_terms_reference
test_survey_worker_terms_reference
test_terms_line_language_free
test_terms_reference_ignores_comments

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
