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
# -------------------------------
# A few lines in this repo must keep a literal old-scheme CPR-<N> ID, because
# reproducing that ID IS their job: the negative assertion literal in
# tests/refactor-design-principles/section-b.sh (B19 proves the stale pointer is
# gone from the CPR-ORTH body — rewrite the literal and the case asserts nothing),
# and the old->new correspondence documented in M1's rationale below. Sweeping
# those lines would destroy the very checks that certify the sweep, so G1 has to
# tolerate them without going blind.
#
# The exception is LINE-scoped on purpose. Excluding the three files wholesale via
# a pathspec would be shorter and permanently wrong: G1 would then never see a
# genuinely stale reference newly introduced ANYWHERE in those files. A line marker
# trades no coverage at all — every unmarked line in the repo is still checked.
#
# When adding a marker is legitimate: only where the OLD ID is load-bearing — an
# assertion literal, or a table documenting the old->new mapping. Prose that merely
# cites a principle is never a candidate; cite it by its semantic code instead.
# Marking a line just to silence G1 on an unswept reference is an abuse of it.
# Enumerate every allowlisted line with:  git grep -n CPR-LEGACY-ID-OK
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

# G1 and M1 are complementary; neither alone certifies a correct sweep. G1 proves the
# OLD numeric IDs are ABSENT, M1 proves the NEW codes that replaced them are the RIGHT
# ones — a sweep rewriting every CPR-4 to CPR-ORTH satisfies G1 and fails only here. [CPR-LEGACY-ID-OK]
#
# M1 asserts the exact per-file OCCURRENCE MULTISET, not mere presence: each expected
# code must occur exactly N times AND every other semantic code must occur zero times.
# Presence alone is too weak — a file whose two CPR-4 references became one CPR-E2C [CPR-LEGACY-ID-OK]
# plus one CPR-ORTH still contains "a CPR-E2C" and would pass a presence check.
#
# Counts are measured against each file's pristine pre-sweep content
# (CPR-1→UO, CPR-2→SSOT, CPR-3→SC, CPR-4→E2C, CPR-5→ORTH, CPR-6→E2E, CPR-8→UNV) [CPR-LEGACY-ID-OK]
# — do not re-derive them.
#
# SCOPE — why this table lists 19 files and not all 164 that mention a CPR ID.
# Extending it to every file was considered and rejected on the merits, twice:
#   1. Cost/benefit. A 164-row table is a second copy of the sweep itself. It would
#      be generated from the same pristine counts the sweep is generated from, so it
#      re-asserts the sweep against its own input rather than against intent.
#   2. Brittleness. Every one of 164 files would then have to update this table on
#      any future CPR-reference edit. The failure that produces is a red test nobody
#      reads, which is worse coverage than an honest 19.
#   3. Residual risk is already covered. G1 proves NO numeric ID survives anywhere in
#      the repo — all 164 files included. What the other 145 lack is only the
#      "landed on the RIGHT code" check, and those are single-reference sites in
#      docs/skills where a mis-map is locally obvious on review. The 19 listed here
#      are the multi-reference and cross-code files, i.e. exactly the sites where a
#      mis-map is invisible to G1 and to the eye.
# rules/core-principles.md is deliberately NOT a row: it is the SSOT being edited,
# its content is asserted structurally by N1/N2/N3/S1/S2/S3/S4, and an occurrence
# count there would duplicate that with a weaker assertion.
#
# MAINTENANCE CONTRACT: this table encodes the prose reference sites of these files.
# Any legitimate future edit that adds or removes a CPR reference in one of them MUST
# update the corresponding count here, or M1 goes red. That brittleness is deliberate
# — an exact multiset is the only thing that can catch a mis-mapping which still lands
# on a syntactically valid code.
DOWNSTREAM_MAPPING="
agents/supervisor.md|CPR-E2C=2 CPR-ORTH=2 CPR-E2E=2
agents/detail-planner.md|CPR-E2C=2
agents/detail-reviewer.md|CPR-ORTH=1
agents/outline-reviewer.md|CPR-ORTH=1
rules/prompt.md|CPR-SSOT=1
rules/workflow-off.md|CPR-ORTH=1
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
docs/architecture/claude-code/workflow.md|CPR-SSOT=2
docs/architecture/claude-code/marker-bypass-contract.md|CPR-SSOT=1 CPR-ORTH=1
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
