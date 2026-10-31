#!/usr/bin/env bash
# tests/hooks/feature-1894-precommit-comment-block-warn/failopen-placement-static.sh
# Tests: hooks/pre-commit, bin/review-comment-block-size, rules/coding/file-split.md
# Tags: comment-block-size, pre-commit, hook, fail-open, ordering, static-guard, scope:issue-specific, scope:feature-1894, layer:TL2

# Part 2 (prefix F) — placement and fail-open: only scanner rc 1 blocks; other rcs pass with
# a diagnostic; the section runs before the early exits and reads no session marker.
# Sourced by the dispatcher, which defines every helper and shared constant.

# ============================================================================
# F1 — scanner rc 3 -> fail-open with a diagnostic, commit still succeeds
# ============================================================================
f1_fail_open_on_internal_error() {
    local repo; repo="$(make_repo f1 rc3 "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo"
    assert_eq "F1/rc-unchanged" "0" "$RC"
    assert_contains "F1/diagnostic-names-the-rc" "${FAILOPEN_NOTICE}3" "$ERR"
    assert_contains "F1/diagnostic-says-commit-continues" "commit continues" "$ERR"
    assert_contains "F1/captured-output-on-stderr" "$ERR_LINE" "$ERR"
    # The one confusion this whole mapping exists to prevent: an outage must not
    # be presented to the committer as a violation.
    assert_absent "F1/not-reported-as-a-block" "$BLOCK_NOTICE" "$OUT$ERR"
}

f1b_fail_open_on_unnamed_rc() {
    # rc 7 is in no branch of the contract. The `else` must be fail-open too, or
    # a future scanner rc silently becomes a commit-blocking verdict.
    local repo; repo="$(make_repo f1b rc7 "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo"
    assert_eq "F1b/rc-unchanged" "0" "$RC"
    assert_contains "F1b/diagnostic-names-the-rc" "${FAILOPEN_NOTICE}7" "$ERR"
    assert_absent "F1b/not-reported-as-a-block" "$BLOCK_NOTICE" "$OUT$ERR"
}

# ============================================================================
# F2 / F3 — clean run: no output, and no `set -u` abort on the success path
# ============================================================================
f2_clean_run_is_silent() {
    local repo; repo="$(make_repo f2 clean "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo"
    assert_eq "F2/rc" "0" "$RC"
    assert_absent "F2/no-scanner-output-echoed" "$SCANNER_HEADER" "$OUT$ERR"
    assert_absent "F2/no-advisory-notice" "comment-block warnings are advisory" "$OUT$ERR"
    assert_absent "F2/no-failopen-diagnostic" "$FAILOPEN_NOTICE" "$OUT$ERR"
}

f3_rc_capture_is_preinitialised() {
    # Regression: `_cb_out="$(...)" || _cb_rc=$?` leaves _cb_rc unset on the
    # success path. Under `set -euo pipefail` the later read aborts the hook
    # with "unbound variable" and blocks an otherwise clean commit — which is a
    # far worse failure now that blocking is a thing this section does at all.
    local repo; repo="$(make_repo f3 clean "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo"
    assert_eq "F3/clean-commit-not-blocked" "0" "$RC"
    assert_absent "F3/no-unbound-variable-abort" "unbound variable" "$ERR"
}

# ============================================================================
# F4 — placement: the section runs BEFORE the unconditional early exits
# ============================================================================
f4_runs_before_early_exit() {
    # A non-GitHub remote is one of the hook's three unconditional `exit 0`
    # early-exits (the private-repo case is its sibling). If the section were
    # inserted after them, this repo would never be scanned — and every case in
    # this suite that uses NON_GITHUB would be passing vacuously.
    local repo; repo="$(make_repo f4 block "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo"
    assert_eq "F4/blocks-despite-early-exit" "1" "$RC"
    assert_contains "F4/scanned-despite-early-exit" "$BLOCK_LINE" "$OUT$ERR"
}

# ============================================================================
# F5 — the section's exit does not swallow downstream verdicts
# ============================================================================
f5_downstream_rules_keep_their_verdict() {
    # No remote at all -> the hook skips the remote/visibility block entirely and
    # reaches the ".env staged" rule, which blocks with exit 1. With a rc-3
    # scanner the comment-block section must fall through, so rc 1 here can only
    # have come from the downstream rule: proof the section neither exited early
    # nor masked what follows it.
    local repo; repo="$(make_repo f5 rc3 none)"
    stage_sample "$repo"
    printf 'FIXTURE_ONLY=1\n' > "$repo/.env"
    git -C "$repo" add -f .env
    run_precommit "$repo" "$repo"
    assert_contains "F5/failopen-diagnostic-emitted" "$FAILOPEN_NOTICE" "$OUT$ERR"
    assert_eq "F5/downstream-exit-code-preserved" "1" "$RC"
    assert_contains "F5/downstream-rule-fired" ".env file(s) staged for commit" "$OUT$ERR"
}

# ============================================================================
# S1 / S2 — static placement and initialisation guards
# ============================================================================
# #2507: sections are the rows of hooks/pre-commit.d/registry.js in run order; the
# comment-block section is hooks/pre-commit.d/checks/comment-block-size.js.
PC_REGISTRY="$SCRIPT_CHECKOUT_ROOT/hooks/pre-commit.d/registry.js"
PC_CB_CHECK="$SCRIPT_CHECKOUT_ROOT/hooks/pre-commit.d/checks/comment-block-size.js"

s1_static_placement() {
    local first_ref private_ref frontmatter_ref
    first_ref="$(grep -n '^  \["comment-block-size",' "$PC_REGISTRY" | head -1 | cut -d: -f1)"
    private_ref="$(grep -n '^  \["repo-visibility",' "$PC_REGISTRY" | head -1 | cut -d: -f1)"
    frontmatter_ref="$(grep -n '^  \["tests-frontmatter",' "$PC_REGISTRY" | head -1 | cut -d: -f1)"
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

# _cb_section — the comment-block check's source (#2507: one Node module).
_cb_section() {
    [ -f "$PC_CB_CHECK" ] && cat "$PC_CB_CHECK"
}

# #2507 retired the bash-only _cb_out/_cb_rc pre-initialisation guard. The shared
# repo identity is the registry's agentsRepoOnly flag, decided once (context.isAgentsRepo).
s2_static_initialisation() {
    local defs row
    defs="$(grep -c 'isAgentsRepo:' "$SCRIPT_CHECKOUT_ROOT/hooks/pre-commit.d/context.js" || true)"
    if [ "$defs" -eq 1 ]; then
        pass "S2: the agents-repo identity is decided exactly once (context.isAgentsRepo)"
    else
        fail "S2: context.isAgentsRepo definition count is $defs, expected 1" \
             "The prompt-extraction backstop and this section must share one implementation (CPR-SSOT)."
    fi
    for row in prompt-extraction comment-block-size; do
        if grep -qE "^  \[\"$row\", \"(open|closed)\", true," "$PC_REGISTRY"; then
            pass "S2: $row is gated by the shared agentsRepoOnly identity"
        else
            fail "S2: $row is not marked agentsRepoOnly in hooks/pre-commit.d/registry.js"
        fi
    done
}

# ============================================================================
# S2c — statically: `exit 1` belongs to the rc-1 branch alone
#
# F1/F1b prove fail-open for the two rc values a test can stage. The static
# check is what generalises it: a single `exit` inside the section, reachable
# only from the rc-1 comparison. Without it, "rc 3 happens to fall through" and
# "rc != 1 falls through by construction" look identical from the outside.
# ============================================================================
s2c_exit_is_confined_to_the_rc1_branch() {
    local section; section="$(_cb_section)"
    if [ -z "$section" ]; then
        fail "S2c: could not locate the comment-block section in hooks/pre-commit (issue #1894)"
        return
    fi
    # #2507: the Node check's `exit 1` is its one `verdict: "block"`; it never ends the hook early.
    local exits
    exits="$(printf '%s\n' "$section" | grep -cF 'verdict: "block"' || true)"
    if [ "$exits" = "1" ]; then
        pass "S2c: the section returns exactly one block verdict"
    else
        fail "S2c: the section returns $exits block verdicts, expected 1" \
             "rc 1 is the only scanner result that may stop the commit."
    fi
    if printf '%s\n' "$section" | grep -qE 'skip-rest|process\.exit'; then
        fail "S2c: the section can end the hook early" \
             "An unconditional success exit here would skip every rule after it."
    else
        pass "S2c: the section never ends the hook early"
    fi
    local rc1_line exit_line
    rc1_line="$(printf '%s\n' "$section" | grep -nF 'if (rc === 1)' | head -1 | cut -d: -f1)"
    exit_line="$(printf '%s\n' "$section" | grep -nF 'verdict: "block"' | head -1 | cut -d: -f1)"
    if [ -n "$rc1_line" ] && [ -n "$exit_line" ] && [ "$rc1_line" -lt "$exit_line" ]; then
        pass "S2c: the block verdict follows an explicit rc === 1 comparison"
    else
        fail "S2c: the block verdict is not guarded by an rc === 1 comparison" \
             "rc1_line=${rc1_line:-none} exit_line=${exit_line:-none}"
    fi
}

# ============================================================================
# S2d — the block has no bypass, by omission
#
# Recorded as an accepted tradeoff in the outline plan: this check is NOT
# suspendable via WORKFLOW_OFF / WORKTREE_OFF. That property is only real while
# the section never reads session-marker state, and the surrounding hook does
# call _session_marker_off() for its other rules — so the absence has to be
# asserted, not assumed.
# ============================================================================
s2d_section_reads_no_session_marker() {
    local section; section="$(_cb_section)"
    if [ -z "$section" ]; then
        fail "S2d: could not locate the comment-block section in hooks/pre-commit (issue #1894)"
        return
    fi
    local hits=""
    local m
    for m in sessionMarkerOff session-markers workflow-off worktree-off WORKFLOW_OFF WORKTREE_OFF; do
        if printf '%s\n' "$section" | grep -qF -- "$m"; then hits="$hits $m"; fi
    done
    if [ -z "$hits" ]; then
        pass "S2d: the section consults no session-marker state"
    else
        fail "S2d: the section references session-marker state:$hits" \
             "The comment-block block is deliberately not suspendable (outline plan)."
    fi
    # Positive control: another check does read the marker, so the absence is the section's own.
    if grep -q 'sessionMarkerOff' "$SCRIPT_CHECKOUT_ROOT/hooks/pre-commit.d/checks/prompt-extraction.js"; then
        pass "S2d/control: the prompt-extraction check does read sessionMarkerOff"
    else
        fail "S2d/control: no other pre-commit check reads sessionMarkerOff" \
             "Without it the absence assertion above proves nothing."
    fi
}

# #2507: the backstop is checks/prompt-extraction.js; it must take repo identity from the
# shared agentsRepoOnly gate (S2), never from a comparison of its own.
s2b_old_inline_comparison_is_gone() {
    local section
    section="$(cat "$SCRIPT_CHECKOUT_ROOT/hooks/pre-commit.d/checks/prompt-extraction.js" 2>/dev/null)"
    if [ -z "$section" ]; then
        fail "S2b: could not locate hooks/pre-commit.d/checks/prompt-extraction.js"
        return
    fi
    if printf '%s\n' "$section" | grep -qE -- '--git-common-dir|isAgentsRepo|sameRepo'; then
        fail "S2b: the backstop check decides repo identity itself" \
             "Repo identity must come from the registry's agentsRepoOnly gate alone."
    else
        pass "S2b: the backstop check resolves no repo identity of its own"
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

f1_fail_open_on_internal_error
f1b_fail_open_on_unnamed_rc
f2_clean_run_is_silent
f3_rc_capture_is_preinitialised
f4_runs_before_early_exit
f5_downstream_rules_keep_their_verdict
s1_static_placement
s2_static_initialisation
s2c_exit_is_confined_to_the_rc1_branch
s2d_section_reads_no_session_marker
s2b_old_inline_comparison_is_gone
s3_file_split_rule_cross_reference
s3b_file_split_rule_thresholds_survive
