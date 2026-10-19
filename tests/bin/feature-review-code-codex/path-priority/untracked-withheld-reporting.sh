# Part of tests/bin/feature-review-code-codex.sh (sourced, not standalone).
# Tests: bin/review-code-codex, bin/lib/review-code-codex/priority-collect.sh
# Tags: codex, review, untracked, withholding, skipped, scope-caveat, base-state, table-driven, scope:issue-specific, pwsh-not-required, TL2
# UW-rows: truthful untracked reporting. Under any base state other than RECORDED/RESOLVED (an omitted --base-state is UNKNOWN) untracked files are never enumerated, so no output may claim "no untracked files": SKIPPED says they were withheld under base state <X>, and a run with a committed diff prints an UNTRACKED-WITHHELD scope line plus a SCOPE CAVEAT in the prompt. Split out of working-tree-target.sh, which is at the 500-line limit.
# TL3 gap: codex is a shell mock, so only the prompt text is observed, never whether a real model weighs the caveat. Mitigation: WORKFLOW_USER_VERIFIED preflight, category merge-base-suspect.

echo ""
echo "--- UW: truthful untracked reporting under untrusted base states ---"

pp_install_capturing_mock
PP_ENV=()
PP_SCRIPT=""

# uw_run <repo> <state> — an omitted state passes no --base-state at all.
uw_run() {
    if [ "$2" = "omitted" ]; then
        pp_exec "$1" --base main --no-log
    else
        pp_exec "$1" --base main --base-state "$2" --no-log
    fi
}

# ---------------------------------------------------------------------------
# UW1: untracked files are the only change. SKIPPED must say they were withheld under the
#      named base state, never "no untracked files". Rows: state given | state SKIPPED names.
# ---------------------------------------------------------------------------
case_begin "untracked-only-skipped-names-withheld-state" "bin/review-code-codex"
UW1_REPO="$(pp_new_repo pp-uw1)"
printf 'UW1-UNTRACKED-MARK\n' > "$UW1_REPO/only-untracked.txt"
while IFS='|' read -r uw_state uw_named; do
    [ -n "$uw_state" ] || continue
    uw_run "$UW1_REPO" "$uw_state"
    uw_skip="$(printf '%s\n' "$PP_OUT_TEXT" | grep -E '^## Codex Review: SKIPPED' || true)"
    if [ -z "$uw_skip" ]; then
        fail "UW1 (state=$uw_state): no SKIPPED verdict for an untracked-only change. Output: $(printf '%s' "$PP_OUT_TEXT" | head -c 300)"
        continue
    fi
    if pp_has_fixed "$uw_skip" "no untracked files"; then
        fail "UW1 (state=$uw_state): SKIPPED claims \"no untracked files\" although untracked files were never enumerated. Line: $uw_skip"
    else
        pass "UW1 (state=$uw_state): SKIPPED does not claim \"no untracked files\""
    fi
    if pp_has_fixed "$uw_skip" "withheld" && pp_has_fixed "$uw_skip" "base state $uw_named"; then
        pass "UW1 (state=$uw_state): SKIPPED says untracked files were withheld under base state $uw_named"
    else
        fail "UW1 (state=$uw_state): SKIPPED does not say untracked files were withheld under base state $uw_named. Line: $uw_skip"
    fi
    if [ -f "$PP_CAPTURE" ]; then
        fail "UW1 (state=$uw_state): codex was invoked although the reviewable diff is empty"
    else
        pass "UW1 (state=$uw_state): codex was never invoked"
    fi
done <<'TABLE'
omitted|UNKNOWN
UNKNOWN|UNKNOWN
SUSPECT|SUSPECT
FALLBACK|FALLBACK
UNRESOLVED|UNRESOLVED
TABLE
case_end

# UW1-control: under a trusted state with nothing changed at all, "no untracked files" is true.
case_begin "clean-repo-skipped-may-say-no-untracked" "bin/review-code-codex"
UW1C_REPO="$(pp_new_repo pp-uw1c)"
for uw_state in RECORDED RESOLVED; do
    uw_run "$UW1C_REPO" "$uw_state"
    if pp_has_fixed "$PP_OUT_TEXT" "## Codex Review: SKIPPED" && pp_has_fixed "$PP_OUT_TEXT" "no untracked files"; then
        pass "UW1-control (state=$uw_state): a clean repo's SKIPPED may still say \"no untracked files\""
    else
        fail "UW1-control (state=$uw_state): expected SKIPPED with \"no untracked files\". Output: $PP_OUT_TEXT"
    fi
done
case_end

# ---------------------------------------------------------------------------
# UW2: a committed diff plus an untracked file. Under an untrusted state the untracked file is
#      dropped, so stdout carries an UNTRACKED-WITHHELD scope line naming the state and the
#      prompt carries a SCOPE CAVEAT about it. The trusted states print neither (control).
# ---------------------------------------------------------------------------
case_begin "committed-diff-reports-untracked-withheld" "bin/lib/review-code-codex/priority-collect.sh"
UW2_REPO="$(pp_new_repo pp-uw2)"
printf 'UW2-COMMITTED-MARK\n' > "$UW2_REPO/committed.txt"
git -C "$UW2_REPO" add committed.txt
git -C "$UW2_REPO" commit -q -m "committed change"
printf 'UW2-UNTRACKED-MARK\n' > "$UW2_REPO/untracked.txt"
while IFS='|' read -r uw_state uw_named; do
    [ -n "$uw_state" ] || continue
    uw_run "$UW2_REPO" "$uw_state"
    uw_scope="$(printf '%s\n' "$PP_OUT_TEXT" | grep -E '^## Codex Review Scope: UNTRACKED-WITHHELD' || true)"
    uw_prompt="$(cat "$PP_CAPTURE" 2>/dev/null || true)"
    if [ -z "$uw_prompt" ]; then
        fail "UW2 (state=$uw_state): no prompt captured. Output: $(printf '%s' "$PP_OUT_TEXT" | head -c 300)"
        continue
    fi
    if pp_has_fixed "$uw_prompt" "UW2-UNTRACKED-MARK"; then
        fail "UW2 (state=$uw_state): untracked content reached the prompt under an untrusted state"
    else
        pass "UW2 (state=$uw_state): untracked content stays withheld"
    fi
    if [ -n "$uw_scope" ] && pp_has_fixed "$uw_scope" "$uw_named"; then
        pass "UW2 (state=$uw_state): stdout carries an UNTRACKED-WITHHELD scope line naming $uw_named"
    else
        fail "UW2 (state=$uw_state): no UNTRACKED-WITHHELD scope line naming $uw_named. Output: $(printf '%s' "$PP_OUT_TEXT" | head -c 300)"
    fi
    if printf '%s\n' "$uw_prompt" | grep -E '^SCOPE CAVEAT:' | grep -qi 'untracked'; then
        pass "UW2 (state=$uw_state): the prompt carries a SCOPE CAVEAT about the withheld untracked files"
    else
        fail "UW2 (state=$uw_state): the prompt carries no SCOPE CAVEAT line about withheld untracked files"
    fi
done <<'TABLE'
omitted|UNKNOWN
UNKNOWN|UNKNOWN
SUSPECT|SUSPECT
TABLE
case_end

# UW2-control: the same repo under a trusted state reviews the untracked file and withholds nothing.
case_begin "trusted-state-reports-no-untracked-withheld" "bin/lib/review-code-codex/priority-collect.sh"
for uw_state in RECORDED RESOLVED; do
    uw_run "$UW2_REPO" "$uw_state"
    if pp_has "$PP_OUT_TEXT" "^## Codex Review Scope: UNTRACKED-WITHHELD"; then
        fail "UW2-control (state=$uw_state): an UNTRACKED-WITHHELD line was printed although untracked files are reviewed"
    else
        pass "UW2-control (state=$uw_state): no UNTRACKED-WITHHELD line under a trusted state"
    fi
    if pp_has_fixed "$(cat "$PP_CAPTURE" 2>/dev/null || true)" "UW2-UNTRACKED-MARK"; then
        pass "UW2-control (state=$uw_state): untracked content is reviewed"
    else
        fail "UW2-control (state=$uw_state): untracked content is missing under a trusted state"
    fi
done
case_end
