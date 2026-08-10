#!/usr/bin/env bash
# tests/feature-1894-precommit-comment-block-warn/failopen-placement-static.sh
# Tests: hooks/pre-commit, bin/review-comment-block-size, rules/coding/file-split.md
# Tags: comment-block-size, pre-commit, hook, fail-open, ordering, static-guard, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 2 of tests/feature-1894-precommit-comment-block-warn.sh — the properties
# that are about the section's *placement and blast radius* rather than about
# its guard: fail-open on a non-zero scanner rc, silence on a clean run, no
# `set -u` abort on the success path, execution before the hook's unconditional
# early exits, and no `exit` of its own.
#
# Sourced by the dispatcher; every helper (run_precommit, make_repo, assert_*)
# and every shared constant is defined there.
# ============================================================================
# P05 — scanner rc != 0 -> fail-open with a diagnostic, commit still succeeds
# ============================================================================
p05_fail_open_on_nonzero_rc() {
    local repo; repo="$(make_repo p05 rc3 "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo"
    assert_eq "P05/rc-unchanged" "0" "$RC"
    assert_contains "P05/diagnostic-on-stderr" \
        "pre-commit: review-comment-block-size rc=3 — comment-block check incomplete (advisory; commit continues)" \
        "$ERR"
    assert_contains "P05/captured-output-on-stderr" "$ERR_LINE" "$ERR"
}

# ============================================================================
# P06 / P07 — clean run: no output, and no `set -u` abort on the success path
# ============================================================================
p06_clean_run_is_silent() {
    local repo; repo="$(make_repo p06 clean "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo"
    assert_eq "P06/rc" "0" "$RC"
    assert_absent "P06/no-scanner-output-echoed" "$SCANNER_HEADER" "$OUT$ERR"
    assert_absent "P06/no-advisory-notice" "comment-block warnings are advisory" "$OUT$ERR"
}

p07_rc_capture_is_preinitialised() {
    # Regression: `_cb_out="$(...)" || _cb_rc=$?` leaves _cb_rc unset on the
    # success path. Under `set -euo pipefail` the later read aborts the hook
    # with "unbound variable" and blocks an otherwise clean commit.
    local repo; repo="$(make_repo p07 clean "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo"
    assert_eq "P07/clean-commit-not-blocked" "0" "$RC"
    assert_absent "P07/no-unbound-variable-abort" "unbound variable" "$ERR"
}

# ============================================================================
# P08 — placement: the section runs BEFORE the unconditional early exits
# ============================================================================
p08_runs_before_early_exit() {
    # A non-GitHub remote is one of the hook's three unconditional `exit 0`
    # early-exits (the private-repo case is its sibling). If the section were
    # inserted after them, this repo would never be scanned.
    local repo; repo="$(make_repo p08 warn "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo"
    assert_eq "P08/rc" "0" "$RC"
    assert_contains "P08/scanned-despite-early-exit" "$WARN_LINE" "$OUT$ERR"
}

# ============================================================================
# P09 — the section contains no `exit`: downstream stages keep their verdict
# ============================================================================
p09_section_has_no_exit() {
    # No remote at all -> the hook skips the remote/visibility block entirely
    # and reaches the ".env staged" rule, which blocks with exit 1. Seeing BOTH
    # the advisory output and rc 1 proves the section neither exited early nor
    # swallowed the downstream verdict.
    local repo; repo="$(make_repo p09 warn none)"
    stage_sample "$repo"
    printf 'FIXTURE_ONLY=1\n' > "$repo/.env"
    git -C "$repo" add -f .env
    run_precommit "$repo" "$repo"
    assert_contains "P09/advisory-output-emitted" "$WARN_LINE" "$OUT$ERR"
    assert_eq "P09/downstream-exit-code-preserved" "1" "$RC"
    assert_contains "P09/downstream-rule-fired" ".env file(s) staged for commit" "$OUT$ERR"
}

# ============================================================================
# S1 / S2 — static placement and initialisation guards
# ============================================================================
s1_static_placement() {
    local first_ref private_ref frontmatter_ref
    first_ref="$(grep -n 'review-comment-block-size' "$PRECOMMIT" | head -1 | cut -d: -f1)"
    private_ref="$(grep -n 'Check if this repo is private' "$PRECOMMIT" | head -1 | cut -d: -f1)"
    frontmatter_ref="$(grep -n 'check-test-frontmatter.sh' "$PRECOMMIT" | head -1 | cut -d: -f1)"
    if [ -z "$first_ref" ]; then
        fail "S1: hooks/pre-commit has no review-comment-block-size section yet (issue #1894)"
        return
    fi
    if [ -n "$private_ref" ] && [ "$first_ref" -lt "$private_ref" ]; then
        pass "S1: section precedes the repo-visibility early-exit block"
    else
        fail "S1: section is at line $first_ref, not before the visibility block at line ${private_ref:-?}"
    fi
    if [ -n "$frontmatter_ref" ] && [ "$first_ref" -gt "$frontmatter_ref" ]; then
        pass "S1: section follows the staged tests/*.sh frontmatter block"
    else
        fail "S1: section is at line $first_ref, not after the frontmatter block at line ${frontmatter_ref:-?}"
    fi
}

s2_static_initialisation() {
    if grep -q '_cb_rc=0' "$PRECOMMIT" && grep -q '_cb_out=""' "$PRECOMMIT"; then
        pass "S2: _cb_out / _cb_rc are pre-initialised before the rc capture"
    else
        fail "S2: hooks/pre-commit does not pre-initialise _cb_out/_cb_rc" \
             "Required so 'set -euo pipefail' cannot abort on the success path."
    fi
    # Counting call sites, not the definition: a helper that exists but is
    # never called (or called from only one of the two places) would satisfy a
    # bare existence grep while leaving the duplication CPR-SSOT forbids.
    local defs calls
    defs="$(grep -c '^[[:space:]]*_is_agents_session_repo[[:space:]]*()' "$PRECOMMIT" || true)"
    calls="$(grep -c '_is_agents_session_repo' "$PRECOMMIT" || true)"
    calls=$((calls - defs))
    if [ "$defs" -eq 1 ]; then
        pass "S2: _is_agents_session_repo() is defined exactly once"
    else
        fail "S2: _is_agents_session_repo() definition count is $defs, expected 1" \
             "The prompt-extraction backstop and this section must share one implementation (CPR-SSOT)."
    fi
    if [ "$calls" -ge 2 ]; then
        pass "S2: _is_agents_session_repo() is called from both consumers ($calls call sites)"
    else
        fail "S2: _is_agents_session_repo() has $calls call site(s), expected >= 2" \
             "Both the prompt-extraction backstop and the comment-block section must call it."
    fi
}

s2b_old_inline_comparison_is_gone() {
    # S7a calls the helper a behaviour-preserving EXTRACTION, and an extraction
    # that leaves the original in place is not one — it is a copy, which is the
    # duplication CPR-SSOT forbids and the exact state a call-site count cannot
    # distinguish from success (the backstop would still "call" the helper while
    # deciding identity with its own inline code).
    #
    # These four locals are the prompt-extraction backstop's own common-dir
    # comparison as it stands before issue #1894. None may survive the edit.
    local leftovers="" v
    for v in _pe_agents_common _pe_repo_common _pe_agents_abs _pe_repo_abs; do
        if grep -q "$v" "$PRECOMMIT"; then leftovers="$leftovers $v"; fi
    done
    if [ -z "$leftovers" ]; then
        pass "S2b: the backstop's inline common-dir comparison is gone"
    else
        fail "S2b: inline common-dir comparison still present in hooks/pre-commit" \
             "leftover variable(s):$leftovers — the helper must REPLACE it, not sit beside it."
    fi

    # Scoped counterpart: the enforce-worktree block earlier in the hook compares
    # --git-common-dir against --git-dir for a different purpose and must stay,
    # so the absence assertion is confined to the backstop section itself. Anchor
    # on the section's own BANNER line (not any prose mention of the phrase) —
    # an ordinary comment elsewhere in the hook (e.g. the CPR-SSOT note above
    # _session_marker_off()) also contains "prompt-extraction backstop" and would
    # open the range too early, swallowing the enforce-worktree block's
    # legitimate --git-common-dir usage.
    local section
    section="$(awk '/^# -+ prompt-extraction backstop/{f=1} f && /^# Check scope tag on staged/{f=0} f' "$PRECOMMIT")"
    if [ -z "$section" ]; then
        fail "S2b: could not locate the prompt-extraction backstop section in hooks/pre-commit"
        return
    fi
    if printf '%s\n' "$section" | grep -qF -- '--git-common-dir'; then
        fail "S2b: the backstop section still resolves --git-common-dir itself" \
             "Repo identity must come from _is_agents_session_repo() alone."
    else
        pass "S2b: the backstop section resolves no common dir of its own"
    fi
    if printf '%s\n' "$section" | grep -q '_is_agents_session_repo'; then
        pass "S2b: the backstop section decides identity via _is_agents_session_repo()"
    else
        fail "S2b: the backstop section does not call _is_agents_session_repo()" \
             "The extraction's whole point is that this consumer uses the helper."
    fi
}

s3_file_split_rule_cross_reference() {
    # rules/coding/file-split.md "Pattern A" is where a developer looks up the
    # 300/500-line policy; the new scanner is the tool that enforces the
    # comment-block half of it, so the reference belongs in that section and
    # nowhere else (CPR-SSOT).
    if [ ! -f "$FILE_SPLIT_RULE" ]; then
        fail "S3: $FILE_SPLIT_RULE not found"
        return
    fi
    local section
    section="$(awk '/^## Pattern A/{f=1;next} /^## /{f=0} f' "$FILE_SPLIT_RULE")"
    if [ -z "$section" ]; then
        fail "S3: rules/coding/file-split.md has no '## Pattern A' section"
        return
    fi
    if printf '%s\n' "$section" | grep -qF 'bin/review-comment-block-size'; then
        pass "S3: Pattern A cross-references bin/review-comment-block-size"
    else
        fail "S3: Pattern A does not mention bin/review-comment-block-size" \
             "Issue #1894 adds that cross-reference line to the Pattern A section."
    fi
}

s3b_file_split_rule_thresholds_survive() {
    # S3 only proves a line was ADDED. The edit lands inside a rule file that is
    # itself under a >100-line prompt budget, so the cheapest way to make room is
    # to reword or drop a neighbouring bullet — and the neighbours here are the
    # numbers every split decision in this repo is made against. This case pins
    # them verbatim so an accidental rewrite is a test failure, not a silent
    # policy change.
    #
    # Each expected line is quoted exactly as rules/coding/file-split.md holds it
    # today; a deliberate policy change is expected to update this table in the
    # same commit.
    if [ ! -f "$FILE_SPLIT_RULE" ]; then
        fail "S3b: $FILE_SPLIT_RULE not found"
        return
    fi
    local body_a body_b
    body_a="$(awk '/^## Pattern A/{f=1;next} /^## /{f=0} f' "$FILE_SPLIT_RULE")"
    body_b="$(awk '/^## Pattern B/{f=1;next} /^## /{f=0} f' "$FILE_SPLIT_RULE")"
    if [ -z "$body_a" ] || [ -z "$body_b" ]; then
        fail "S3b: rules/coding/file-split.md is missing a Pattern A or Pattern B section"
        return
    fi
    local name pattern want
    while IFS='|' read -r name pattern want; do
        [ -z "${name//[[:space:]]/}" ] && continue
        [[ "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        pattern="${pattern//[[:space:]]/}"
        want="${want# }"
        want="${want%"${want##*[![:space:]]}"}"
        local hay
        case "$pattern" in
            A) hay="$body_a" ;;
            *) hay="$body_b" ;;
        esac
        if printf '%s\n' "$hay" | grep -qF -- "$want"; then
            pass "S3b/$name"
        else
            fail "S3b/$name" \
                 "Pattern $pattern no longer contains: $want"
        fi
    done <<'TABLE'
pattern-a-line-thresholds   | A | - WARN: >300 lines. HARD (must split): >500 lines.
pattern-a-dispatch-only     | A | Keep `<name>.<ext>` as dispatch + re-export only; no logic inside it.
pattern-a-private-sibling   | A | Entrypoint-private modules: sibling `<name>/` folder.
pattern-a-shared-lib        | A | Shared across multiple entrypoints: adjacent `lib/`
pattern-b-line-thresholds   | B | - WARN: >100 lines. HARD (must split): >200 lines.
pattern-b-skill-entrypoint  | B | Keep `SKILL.md` as the prompt entrypoint; never reduce it to dispatch-only.
TABLE
    # The two budgets must stay distinct: collapsing Pattern B onto Pattern A's
    # numbers would read as "prompt files may grow to 300 lines".
    if printf '%s\n' "$body_b" | grep -qF -- '>300 lines'; then
        fail "S3b/patterns-not-conflated" \
             "Pattern B now carries Pattern A's 300-line threshold."
    else
        pass "S3b/patterns-not-conflated"
    fi
}

p05_fail_open_on_nonzero_rc
p06_clean_run_is_silent
p07_rc_capture_is_preinitialised
p08_runs_before_early_exit
p09_section_has_no_exit
s1_static_placement
s2_static_initialisation
s2b_old_inline_comparison_is_gone
s3_file_split_rule_cross_reference
s3b_file_split_rule_thresholds_survive
