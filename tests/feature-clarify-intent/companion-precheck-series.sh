#!/usr/bin/env bash
# tests/feature-clarify-intent/companion-precheck-series.sh
# Tests: skills/clarify-intent/SKILL.md, skills/_shared/judge-decomposition.md, skills/clarify-intent/scripts/precheck-companions.sh
# Tags: workflow, clarify-intent, companion-issues, precheck, decomposition, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Whether clarify-intent invokes precheck-companions.sh at runtime in a live
#   session, or whether the batch multiSelect AskUserQuestion renders correctly.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
#
# Companion precheck and CI-2b rework contracts (#1048).
#   CI-PC-*: static content assertions against the worktree SKILL.md
#   CI-JD-*: provenance annotations in skills/_shared/judge-decomposition.md
#   PC-SH-*: behavioral tests for precheck-companions.sh
# Pre-implementation RED: all cases FAIL until the rework lands via /write-code.
# Exit 0 always — this is a contract test, not a CI gate yet.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

JUDGE_DECOMP="$LOCAL_REPO_ROOT/skills/_shared/judge-decomposition.md"
PRECHECK="$LOCAL_REPO_ROOT/skills/clarify-intent/scripts/precheck-companions.sh"

echo "=== clarify-intent companion precheck contracts (#1048) ==="
echo ""

# ci2b_block — print the CI-2b step region (from the CI-2b label line up to
# the next top-level CI-* label, or 30 lines when no next label exists).
ci2b_block() {
    local ci2b_line next_ci_line
    ci2b_line=$(grep -n "CI-2b" "$LOCAL_SKILL_MD" | head -1 | cut -d: -f1)
    [ -z "$ci2b_line" ] && return 1
    next_ci_line=$(awk -v start="$ci2b_line" 'NR>start && /^CI-[A-Z0-9]/ {print NR; exit}' "$LOCAL_SKILL_MD")
    if [ -n "$next_ci_line" ]; then
        awk -v s="$ci2b_line" -v e="$next_ci_line" 'NR>=s && NR<e' "$LOCAL_SKILL_MD"
    else
        awk -v s="$ci2b_line" 'NR>=s' "$LOCAL_SKILL_MD" | head -30
    fi
}

# CI-PC-1: SKILL.md references precheck-companions.sh
assert_contains "$LOCAL_SKILL_MD" "precheck-companions\.sh" \
    "CI-PC-1: SKILL.md references precheck-companions.sh (pre-implementation until rework)"

# CI-PC-2: SKILL.md references reference/companion-batch-presentation.md
assert_contains "$LOCAL_SKILL_MD" "reference/companion-batch-presentation\.md" \
    "CI-PC-2: SKILL.md references reference/companion-batch-presentation.md (pre-implementation until rework)"

# CI-PC-3: CI-2b step region no longer performs an immediate WIP claim
# (no wip-set-single.sh reference inside CI-2b — the claim moves to
# clarify-commit-scope.sh after CI-5).
if [ -f "$LOCAL_SKILL_MD" ]; then
    BLOCK=$(ci2b_block)
    if [ -z "$BLOCK" ]; then
        fail "CI-PC-3: CI-2b section not found in SKILL.md"
    elif echo "$BLOCK" | grep -qE "wip-set-single\.sh"; then
        fail "CI-PC-3: CI-2b still references wip-set-single.sh (rework not yet applied)"
    else
        pass "CI-PC-3: CI-2b no longer references wip-set-single.sh"
    fi
else
    fail "CI-PC-3: LOCAL_SKILL_MD not found"
fi

# CI-PC-4: clarify-commit-scope.sh invoked AFTER CI-5 and BEFORE CI-C0/CI-C1
if [ -f "$LOCAL_SKILL_MD" ]; then
    CI5_LINE=$(grep -n "^CI-5\b" "$LOCAL_SKILL_MD" | head -1 | cut -d: -f1)
    CCS_LINE=$(grep -n "clarify-commit-scope" "$LOCAL_SKILL_MD" | head -1 | cut -d: -f1)
    CIC0_LINE=$(grep -n "^CI-C0\b" "$LOCAL_SKILL_MD" | head -1 | cut -d: -f1)
    if [ -n "$CI5_LINE" ] && [ -n "$CCS_LINE" ] && [ -n "$CIC0_LINE" ] \
        && [ "$CCS_LINE" -gt "$CI5_LINE" ] && [ "$CCS_LINE" -lt "$CIC0_LINE" ]; then
        pass "CI-PC-4: clarify-commit-scope.sh invoked after CI-5 and before CI-C0"
    else
        fail "CI-PC-4: clarify-commit-scope.sh not yet invoked between CI-5 and CI-C0 (pre-implementation; ci5_ln=${CI5_LINE:-missing} ccs_ln=${CCS_LINE:-missing} cic0_ln=${CIC0_LINE:-missing})"
    fi
else
    fail "CI-PC-4: LOCAL_SKILL_MD not found"
fi

# CI-PC-5: CI-2b does NOT contain per-candidate sequential AskUserQuestion.
# Per-candidate markers: "for each TSV line ... AskUserQuestion" iteration and
# the per-candidate "Yes (add)" option literal. A batch multiSelect
# AskUserQuestion may legitimately remain, so only these markers are checked.
if [ -f "$LOCAL_SKILL_MD" ]; then
    BLOCK=$(ci2b_block)
    if [ -z "$BLOCK" ]; then
        fail "CI-PC-5: CI-2b section not found in SKILL.md"
    elif echo "$BLOCK" | grep -qE "for each TSV line.*AskUserQuestion|one \`AskUserQuestion\`|Yes \(add\)"; then
        fail "CI-PC-5: CI-2b still has per-candidate sequential AskUserQuestion (batch rework not yet applied)"
    else
        pass "CI-PC-5: CI-2b no longer has per-candidate sequential AskUserQuestion"
    fi
else
    fail "CI-PC-5: LOCAL_SKILL_MD not found"
fi

# CI-JD-1..3: provenance annotations in judge-decomposition.md
assert_contains "$JUDGE_DECOMP" '\[origin: seed\]' \
    "CI-JD-1: judge-decomposition.md contains [origin: seed] provenance annotation (pre-implementation until rework)"
assert_contains "$JUDGE_DECOMP" '\[origin: companion #' \
    "CI-JD-2: judge-decomposition.md contains [origin: companion #<N>] annotation (pre-implementation until rework)"
assert_contains "$JUDGE_DECOMP" '\(companion-driven\)' \
    "CI-JD-3: judge-decomposition.md contains (companion-driven) text (pre-implementation until rework)"

# ---------------------------------------------------------------------------
# PC-SH-*: behavioral tests for precheck-companions.sh.
# Pre-implementation RED: each case FAILs while the script is missing.
#
# Mock strategy: a fake AGENTS_CONFIG_DIR tree carries a companion-search.sh
# mock at skills/clarify-intent/scripts/, the precheck script itself is COPIED
# into that tree and invoked from there (so both $AGENTS_CONFIG_DIR-based and
# dirname-$0 sibling resolution hit the mock), and the mock dir is also
# prepended to PATH. A permissive gh mock absorbs any candidate-metadata calls.
# The whole file already runs under a 120s alarm (re-exec guard in _lib.sh).
# ---------------------------------------------------------------------------
if [ -f "$PRECHECK" ]; then
    PC_TMP="$(mktemp -d)"
    PC_ACD="$PC_TMP/acd"
    PC_SCRIPTS="$PC_ACD/skills/clarify-intent/scripts"
    mkdir -p "$PC_SCRIPTS" "$PC_TMP/mock-bin"
    cp "$PRECHECK" "$PC_SCRIPTS/precheck-companions.sh"
    PC_RUN="$PC_SCRIPTS/precheck-companions.sh"

    write_companion_search_mock() {
        # $1 = variant: "one" (one ident-only candidate) | "none" (exit 1)
        if [ "$1" = "none" ]; then
            printf '#!/usr/bin/env bash\nexit 1\n' > "$PC_SCRIPTS/companion-search.sh"
        else
            printf '#!/usr/bin/env bash\nprintf "201\\tSome title\\tident:worktree-end\\tOPEN\\n"\nexit 0\n' > "$PC_SCRIPTS/companion-search.sh"
        fi
        chmod +x "$PC_SCRIPTS/companion-search.sh"
        cp "$PC_SCRIPTS/companion-search.sh" "$PC_TMP/mock-bin/companion-search.sh"
    }

    # Permissive gh mock (empty-ish JSON for any query).
    printf '#!/usr/bin/env bash\necho "{}"\nexit 0\n' > "$PC_TMP/mock-bin/gh"
    chmod +x "$PC_TMP/mock-bin/gh"

    ORIG_PATH="$PATH"
    ORIG_ACD="${AGENTS_CONFIG_DIR:-}"
    export PATH="$PC_TMP/mock-bin:$PATH"
    export AGENTS_CONFIG_DIR="$PC_ACD"

    # PC-SH-1: candidates exist → exit 0, first stdout line has 7 TSV columns
    write_companion_search_mock one
    OUT=$(bash "$PC_RUN" --seed 100 --exclude 100 2>/dev/null)
    RC=$?
    COL_COUNT=$(printf '%s\n' "$OUT" | head -1 | awk -F'\t' '{print NF}')
    if [ "$RC" -eq 0 ] && [ "$COL_COUNT" -eq 7 ]; then
        pass "PC-SH-1: precheck-companions.sh exits 0, first line has 7 tab-separated columns"
    else
        fail "PC-SH-1: expected exit=0 7-col TSV; got rc=$RC cols=${COL_COUNT:-0} out='$OUT'"
    fi

    # PC-SH-2: ident-only candidate (no file/xref/sibling/kw tag) is annotated
    # low-purity in the purity-flag column — not dropped.
    if printf '%s\n' "$OUT" | head -1 | grep -q "low-purity"; then
        pass "PC-SH-2: ident-only candidate carries low-purity purity-flag"
    else
        fail "PC-SH-2: expected low-purity flag for ident-only candidate; got out='$OUT'"
    fi

    # PC-SH-3: no candidates (companion-search exits 1) → exit 1
    write_companion_search_mock none
    bash "$PC_RUN" --seed 100 --exclude 100 >/dev/null 2>&1
    RC3=$?
    if [ "$RC3" -eq 1 ]; then
        pass "PC-SH-3: no candidates (companion-search exits 1) → precheck exits 1"
    else
        fail "PC-SH-3: expected exit=1 when no candidates; got rc=$RC3"
    fi

    # PC-SH-4: --output-file → JSON snapshot with baseline verdict/signals +
    # per-candidate entries
    write_companion_search_mock one
    OUT_FILE="$PC_TMP/output.json"
    bash "$PC_RUN" --seed 100 --exclude 100 --output-file "$OUT_FILE" >/dev/null 2>&1
    RC4=$?
    JSON_OK=0
    if [ -f "$OUT_FILE" ] && node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$OUT_FILE" 2>/dev/null; then
        JSON_OK=1
    fi
    if [ "$RC4" -eq 0 ] && [ "$JSON_OK" -eq 1 ] \
        && grep -q "201" "$OUT_FILE" 2>/dev/null; then
        pass "PC-SH-4: --output-file → parseable JSON snapshot containing candidate entry"
    else
        fail "PC-SH-4: expected exit=0 + parseable JSON with candidate #201; got rc=$RC4 json_ok=$JSON_OK"
    fi

    export PATH="$ORIG_PATH"
    if [ -n "$ORIG_ACD" ]; then export AGENTS_CONFIG_DIR="$ORIG_ACD"; else unset AGENTS_CONFIG_DIR; fi
    rm -rf "$PC_TMP"
else
    fail "PC-SH-1: precheck-companions.sh not yet present (expected RED before /write-code)"
    fail "PC-SH-2: precheck-companions.sh not yet present (expected RED before /write-code)"
    fail "PC-SH-3: precheck-companions.sh not yet present (expected RED before /write-code)"
    fail "PC-SH-4: precheck-companions.sh not yet present (expected RED before /write-code)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"

exit 0
