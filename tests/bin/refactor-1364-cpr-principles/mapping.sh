#!/bin/bash
# tests/refactor-1364-cpr-principles/mapping.sh
# Tests: agents/supervisor.md, agents/detail-planner.md, skills/survey-code/SKILL.md, skills/survey-history/SKILL.md, install/win/dotfileslink.ps1, docs/architecture/claude-code/workflow.md
# Tags: core-principles, refactor, scope:common
#
# Fragment of tests/refactor-1364-cpr-principles.sh — sourced by the parent, not
# run directly. Owns the DOWNSTREAM SWEEP: legacy §N references are gone (N4), no
# CPR-<N> numeric ID survives anywhere (G1), and every reference site carries the
# CORRECT new semantic code in the right quantity (M1).
#
# Depends on the parent for: AGENTS_DIR, ALL_CPR_CODES, cpr_occurrences, pass, fail.

# The six downstream prompt files that carried legacy §N cross-references. Was six
# near-identical cases (N4..N9); one table keeps the semantics identical — missing
# file is a prerequisite failure, a surviving §[1-9] fails naming the file — and
# keeps per-file PASS/FAIL output so a regression still points at the culprit.
LEGACY_SECTION_REF_FILES="
agents/supervisor.md
skills/survey-history/SKILL.md
agents/detail-planner.md
agents/detail-reviewer.md
agents/outline-reviewer.md
skills/survey-code/SKILL.md
"

test_N4_downstream_no_legacy_section_ref() {
    local rel f
    for rel in $LEGACY_SECTION_REF_FILES; do
        f="$AGENTS_DIR/$rel"
        if [ ! -f "$f" ]; then
            fail "N4[$rel]: file not found (prerequisite)"
        elif grep -qE "§[1-9]" "$f"; then
            fail "N4[$rel]: legacy §N reference still present"
        else
            pass "N4[$rel]: no legacy §N reference"
        fi
    done
}

# ============================================================================
# G: completion gate — SSOT for the exclude pathspec list
# ============================================================================

# LINE-SCOPED LEGACY-ID ALLOWLIST
# A few lines must keep a literal old-scheme CPR-<N> ID because reproducing it IS their
# job — an assertion literal (tests/refactor-design-principles/section-b.sh B19) or the
# old->new mapping table in M1's rationale below; sweeping them would destroy the checks
# that certify the sweep. The exception is LINE-scoped, never file-scoped: a pathspec
# exclusion would blind G1 to a genuinely stale reference newly added in those files,
# whereas a line marker costs no coverage anywhere else.
# Legitimate only where the OLD ID is load-bearing; prose that merely cites a principle
# uses the semantic code instead. Marking a line to silence G1 on an unswept reference
# is an abuse of it. Enumerate the allowlist with:  git grep -n CPR-LEGACY-ID-OK
CPR_LEGACY_ID_MARKER='CPR-LEGACY-ID-OK'

# Fail-closed: zero UNMARKED hits is the ONLY pass. Surviving unmarked lines mean
# the sweep is incomplete; exit >=2 means git itself failed, which cannot certify
# anything and stays distinct from the empty-result case.
test_G1_no_residual_numeric_cpr() {
    local hits rc had_errexit residual
    # This file runs under `set -u` only. Suspend errexit for the git grep so a
    # non-zero exit cannot abort before rc is inspected, then restore exactly the
    # prior state (a bare `set -e` here would newly enable errexit for the run).
    case "$-" in *e*) had_errexit=1 ;; *) had_errexit=0 ;; esac
    set +e
    # -n, not -l: the allowlist is line-scoped, so the filter needs lines, not files.
    hits=$(cd "$AGENTS_DIR" && git grep -nE 'CPR-[0-9]' -- \
             ':(exclude)docs/history.md' \
             ':(exclude)docs/history/*' \
             ':(exclude)changelog/*' 2>&1)
    rc=$?
    # Drop allowlisted lines (and the blank line printf emits for empty input);
    # whatever survives is a genuine residue.
    residual=$(printf '%s\n' "$hits" \
                 | grep -vF "$CPR_LEGACY_ID_MARKER" \
                 | grep -vE '^[[:space:]]*$')
    if [ "$had_errexit" -eq 1 ]; then set -e; fi
    case "$rc" in
      1) pass "G1: no residual CPR-<N> numeric IDs outside append-only records" ;;
      0) if [ -z "$residual" ]; then
             pass "G1: every surviving CPR-<N> line carries the $CPR_LEGACY_ID_MARKER marker"
         else
             fail "G1: unmarked residual CPR-<N> found in: $residual"
         fi ;;
      *) fail "G1: git grep failed (exit $rc) — cannot certify completion: $hits" ;;
    esac
}

# ============================================================================
# M: mapping cases — every reference site carries the CORRECT new code
# ============================================================================

# G1 and M1 are complementary: G1 proves the OLD numeric IDs are ABSENT, M1 proves the
# NEW codes that replaced them are the RIGHT ones. M1 asserts the exact per-file
# OCCURRENCE MULTISET (each expected code exactly N times, every other code zero times),
# because presence alone stays green when two references collapse onto one code.

# Counts are measured against each file's pristine pre-sweep content
# (CPR-1→UO, CPR-2→SSOT, CPR-3→SC, CPR-4→E2C, CPR-5→ORTH, CPR-6→E2E, CPR-8→UNV) [CPR-LEGACY-ID-OK]
# — do not re-derive them.

# SCOPE: the table lists the multi-reference and cross-code files, not every file that
# mentions a CPR ID. A full table would re-assert the sweep against its own input, force
# every file to edit this list on any reference change, and add nothing G1 does not
# already cover — the unlisted sites are single-reference ones where a mis-map is locally
# obvious on review. rules/core-principles.md is deliberately NOT a row: it is the SSOT
# being edited, and N1/N2/N3/S1/S2/S3/S4 assert its content structurally.

# MAINTENANCE CONTRACT: any edit that adds or removes a CPR reference in a listed file
# MUST update its count here, or M1 goes red. The brittleness is deliberate — an exact
# multiset is the only thing that catches a mis-mapping onto a syntactically valid code.
DOWNSTREAM_MAPPING="
agents/supervisor.md|CPR-E2C=2 CPR-ORTH=2 CPR-E2E=2
agents/detail-planner.md|CPR-E2C=2
agents/detail-reviewer.md|CPR-ORTH=1
agents/outline-reviewer.md|CPR-ORTH=1
rules/prompt.md|CPR-SSOT=1
rules/coding/nodejs.md|CPR-ORTH=1
skills/_shared/test-design.md|CPR-ORTH=1
skills/survey-code/SKILL.md|CPR-E2C=1
skills/clarify-intent/SKILL.md|CPR-ORTH=1
skills/survey-history/SKILL.md|CPR-E2C=1
skills/issue-create/scripts/eval-confirm-gate.sh|CPR-ORTH=1
skills/review-code-security/scripts/run-quality-gates.sh|CPR-SC=1
install/win/dotfileslink.ps1|CPR-SSOT=1 CPR-ORTH=2
install/linux/dotfileslink.sh|CPR-SSOT=1 CPR-ORTH=1
install/path-exposed-commands.txt|CPR-SSOT=1 CPR-ORTH=1
docs/architecture/claude-code/workflow.md|CPR-SSOT=3 CPR-UNV=1
docs/architecture/claude-code/marker-bypass-contract.md|CPR-SSOT=1 CPR-ORTH=2
docs/architecture/claude-code/settings.md|CPR-SC=1 CPR-ORTH=1 CPR-UNV=1
"

test_M1_downstream_mapping() {
    local rel spec f pair code want got seen problems
    # Fed by heredoc, not a pipe: a `... | while` subshell would discard every
    # PASS/FAIL increment made inside the loop.
    while IFS='|' read -r rel spec; do
        [ -z "$rel" ] && continue
        f="$AGENTS_DIR/$rel"
        if [ ! -f "$f" ]; then
            fail "M1[$rel]: file not found (prerequisite)"
            continue
        fi
        problems=""
        seen=" "
        # (a) every expected code occurs exactly the stated number of times.
        for pair in $spec; do
            code="${pair%%=*}"
            want="${pair#*=}"
            seen="$seen$code "
            got="$(cpr_occurrences "$code" "$f")"
            [ "$got" = "$want" ] \
                || problems="$problems; $code occurs $got time(s), expected $want"
        done
        # (b) every OTHER semantic code occurs zero times — (a)+(b) make it a multiset.
        for code in $ALL_CPR_CODES; do
            case "$seen" in *" $code "*) continue ;; esac
            got="$(cpr_occurrences "$code" "$f")"
            [ "$got" = "0" ] \
                || problems="$problems; unexpected $code occurs $got time(s), expected 0"
        done
        if [ -z "$problems" ]; then
            pass "M1[$rel]: exact occurrence multiset matches ($spec)"
        else
            fail "M1[$rel]: occurrence multiset wrong$problems"
        fi
    done <<EOF
$DOWNSTREAM_MAPPING
EOF
}
