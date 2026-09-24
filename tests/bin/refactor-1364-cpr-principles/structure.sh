#!/bin/bash
# tests/refactor-1364-cpr-principles/structure.sh
# Tests: rules/core-principles.md
# Tags: core-principles, refactor, scope:common
#
# Fragment of tests/refactor-1364-cpr-principles.sh — sourced by the parent, not
# run directly. Owns the STRUCTURE of rules/core-principles.md itself: which CPR
# headers exist (N1/N2/S1), what CPR-WPH must say (N3), which legacy forms must be
# gone (L1/L2), the canonical order (S2), and that each heading carries a body
# (S3) whose content is the right one (S4).
#
# Depends on the parent for: CORE, cpr_section, pass, fail.

# ============================================================================
# N: positive cases — expected structure after the refactor
# ============================================================================

test_N1_all_cpr_headers_present() {
    if [ ! -f "$CORE" ]; then
        fail "N1: rules/core-principles.md not found (prerequisite)"
        return
    fi
    local missing=""
    local code
    for code in UO WPH SC SSOT E2C ORTH E2E NRS UNV; do
        if ! grep -qE "^## CPR-${code}\b" "$CORE"; then
            missing="$missing CPR-$code"
        fi
    done
    if [ -z "$missing" ]; then
        pass "N1: all 9 semantic CPR headers present (UO WPH SC SSOT E2C ORTH E2E NRS UNV)"
    else
        fail "N1: missing CPR headers:$missing"
    fi
}

test_N2_cpr_wph_new_principle() {
    if [ ! -f "$CORE" ]; then
        fail "N2: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qE "^## CPR-WPH\b" "$CORE"; then
        pass "N2: '## CPR-WPH' new principle header present"
    else
        fail "N2: '## CPR-WPH' header NOT found in rules/core-principles.md"
    fi
}

# N3 pins the SUBSTANCE of CPR-WPH — "why precedes how" — and nothing finer. The
# final wording is decided at write-code, so an exact-phrase assertion would freeze
# the author's prose or go stale on the first rewrite. What must not drift is that
# the body (a) names both sides of the ordering at all, and (b) puts the why side
# first. That is the principle; anything beyond it is prose taste, not contract.
#
# WHY THIS IS DELIBERATELY THIN — do not "restore" the older, stricter assertions:
# an earlier revision of N3 also required the tokens `invariant`, `failure` and
# `mechanism`, plus a literal `CPR-UO` clause declaring CPR-WPH orthogonal to
# CPR-UO. That clause was REMOVED from rules/core-principles.md by an explicit
# repo-owner decision in #1858: CPR-UO and CPR-WPH are independent principles,
# applied separately, deliberately un-chained and not ordered relative to each
# other. Re-adding a `CPR-UO` token requirement here would re-introduce exactly
# the conflict #1858 resolved and would block the approved wording. Likewise the
# three fixed vocabulary tokens: CPR entries are HIGH-ABSTRACTION policy, so N3
# must not pile fine-grained prose obligations onto one of them.
#
# LIMIT OF STATIC CHECKING — raised and REJECTED in review rounds 2 and 3; do not
# re-raise it as an oversight. Whether the sentence is SEMANTICALLY good — whether
# it genuinely teaches why-before-how rather than merely containing the words — is
# not statically decidable. Any grep or keyword heuristic would fake the guarantee:
# it would go green on prose that names both sides and says nothing, which is
# strictly worse than an honest gap. Presence plus ordering is the strongest static
# assurance available here. The obligation to judge the substance lives with the
# human at write-code and with the reviewer at review-code — not in this file.
#
# Token matching is WORD-BOUNDED and case-insensitive: a bare substring `how` fires
# inside `show`, `however` and `somehow`, and `detail` must also accept `details`.
WPH_WHY_TOKENS='\b(why|background|context)\b'
WPH_HOW_TOKENS='\b(how|approach|details?|mechanism|resolve)\b'

test_N3_cpr_wph_content() {
    if [ ! -f "$CORE" ]; then
        fail "N3: rules/core-principles.md not found (prerequisite)"
        return
    fi
    local body flat missing="" order_problem="" why_off how_off
    body="$(cpr_section WPH)"
    if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
        fail "N3: CPR-WPH section body is empty — a header alone does not carry the principle"
        return
    fi

    # Ordering by CHARACTER OFFSET into the body flattened to a single string, not by
    # line number. Line granularity cannot separate "why, therefore how" from "how,
    # because why" — both are line 1, so `why_ln >= how_ln` scores the second as
    # compliant. Offsets order them correctly within one line. The same grep also
    # answers the presence question, so presence and order share one measurement.
    flat="$(printf '%s' "$body" | tr '\n' ' ')"
    why_off="$(printf '%s' "$flat" | grep -obiE "$WPH_WHY_TOKENS" | head -1 | cut -d: -f1)"
    how_off="$(printf '%s' "$flat" | grep -obiE "$WPH_HOW_TOKENS" | head -1 | cut -d: -f1)"

    [ -n "$why_off" ] || missing="$missing why-side(why|background|context)"
    [ -n "$how_off" ] || missing="$missing how-side(how|approach|detail(s)|mechanism|resolve)"

    # Skipped when either side is absent — absence is already reported above, and
    # reporting it twice would misattribute a missing token to bad order.
    if [ -n "$why_off" ] && [ -n "$how_off" ] && [ "$why_off" -ge "$how_off" ]; then
        order_problem="CPR-WPH body reaches the how side first (char offset $how_off) and the why side only at char offset $why_off — 'why precedes how' requires the reverse"
    fi

    if [ -n "$missing" ]; then
        fail "N3: CPR-WPH body missing required content point(s):$missing"
    fi
    if [ -n "$order_problem" ]; then
        fail "N3: $order_problem"
    fi
    if [ -z "$missing" ] && [ -z "$order_problem" ]; then
        pass "N3: CPR-WPH body names both sides and states the why ahead of the how"
    fi
}

# ============================================================================
# L: negative cases — legacy forms must be gone from core-principles.md
# ============================================================================

test_L1_no_legacy_section_ref_in_core() {
    if [ ! -f "$CORE" ]; then
        fail "L1: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qE "§[1-9]" "$CORE"; then
        fail "L1: legacy §N cross-reference still present in rules/core-principles.md"
    else
        pass "L1: no legacy §N cross-reference in rules/core-principles.md"
    fi
}

test_L2_no_old_numbered_header() {
    if [ ! -f "$CORE" ]; then
        fail "L2: rules/core-principles.md not found (prerequisite)"
        return
    fi
    if grep -qE "^## [0-9]+\." "$CORE"; then
        fail "L2: legacy '## N.' numbered header still present in rules/core-principles.md"
    else
        pass "L2: no legacy '## N.' numbered header in rules/core-principles.md"
    fi
}

# ============================================================================
# S: structural cases — exact CPR header count, canonical ordering, real bodies
# ============================================================================

test_S1_exactly_9_cpr_headers() {
    if [ ! -f "$CORE" ]; then
        fail "S1: rules/core-principles.md not found (prerequisite)"
        return
    fi
    local count
    count="$(grep -c "^## CPR-" "$CORE")"
    if [ "$count" -eq 9 ]; then
        pass "S1: exactly 9 '## CPR-' headers"
    else
        fail "S1: expected 9 '## CPR-' headers, found $count"
    fi
}

# S2: set membership (N1) cannot catch a reordering regression — the canonical
# order is itself a deliverable of #1858, so assert the emitted sequence.
test_S2_header_order() {
    if [ ! -f "$CORE" ]; then
        fail "S2: rules/core-principles.md not found (prerequisite)"
        return
    fi
    local expected="UO WPH SC SSOT E2C ORTH E2E NRS UNV"
    local actual
    actual="$(grep -n "^## CPR-" "$CORE" \
        | sed -E 's/^[0-9]+:## CPR-([A-Za-z0-9]+).*/\1/' \
        | tr '\n' ' ' \
        | sed -E 's/ +$//')"
    if [ "$actual" = "$expected" ]; then
        pass "S2: CPR headers appear in canonical order ($expected)"
    else
        fail "S2: CPR header order mismatch — expected [$expected], got [$actual]"
    fi
}

# N1/S1/S2/B16 are all header-only: a section whose body was dropped still has its
# heading, so every one of them stays green. That is a live risk here because #1858
# reorders rules/core-principles.md by hand, and hand-moving nine sections is exactly
# where a body gets left behind. S3 is the guard that a heading carries content.
#
# Non-empty is the assertion, deliberately with no minimum-size or "must contain a
# sentence-ending period" threshold: principle bodies are legitimately terse and may
# end in a bullet list, a code span, or a colon, so any such threshold would fire on
# valid prose while adding no signal a truncation check does not already give.
test_S3_all_sections_non_empty() {
    if [ ! -f "$CORE" ]; then
        fail "S3: rules/core-principles.md not found (prerequisite)"
        return
    fi
    local empty="" code body
    for code in UO WPH SC SSOT E2C ORTH E2E NRS UNV; do
        body="$(cpr_section "$code")"
        if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
            empty="$empty CPR-$code"
        fi
    done
    if [ -z "$empty" ]; then
        pass "S3: all 9 CPR sections carry a non-empty body"
    else
        fail "S3: CPR section(s) with a heading but an empty body:$empty"
    fi
}

# S4 is what S3 cannot be. S3 proves each heading has SOME body; S4 proves it has the
# RIGHT body. #1858 renames and REORDERS nine sections by hand, and the failure mode a
# hand-reorder actually produces is not a dropped body — it is a body landing under the
# neighbouring heading. Swap the CPR-E2C and CPR-ORTH bodies and N1, S1, S2, S3 all stay
# green: nine headers, right order, nine non-empty bodies, every principle still on the
# page. Only an anchor-to-section binding catches it.
#
# The anchors are short verbatim substrings of the CURRENT bodies, chosen to be the
# load-bearing phrase of each principle rather than incidental wording, so a rewrite that
# preserves the principle keeps them. #1858 is a rename-and-reorder, not a rewrite: the
# bodies are intended to move unchanged, so anchor drift here is a signal, not noise. If
# a future change genuinely rewords a principle, update the anchor with it.
#
# CPR-WPH is deliberately absent: it is authored fresh at write-code, so no verbatim
# substring of it exists to anchor against. Its content is pinned by N3 instead.
CPR_SECTION_ANCHORS="
UO|Serve the user in front of you
SC|5W1H
SSOT|One canonical location owns each fact
E2C|merged, replaced, or restructured
ORTH|every symmetric member shares it
E2E|the whole pipeline
NRS|convey what it contains
UNV|Prefer the general solution over the special case
"

test_S4_section_anchor_phrases() {
    if [ ! -f "$CORE" ]; then
        fail "S4: rules/core-principles.md not found (prerequisite)"
        return
    fi
    local code anchor body problems=""
    # Heredoc, not a pipe: a `... | while` subshell would discard the accumulated
    # $problems and every pass()/fail() increment made inside the loop.
    while IFS='|' read -r code anchor; do
        [ -z "$code" ] && continue
        body="$(cpr_section "$code")"
        if ! printf '%s\n' "$body" | grep -qF "$anchor"; then
            problems="$problems; CPR-$code body does not contain its anchor phrase [$anchor]"
        fi
    done <<EOF
$CPR_SECTION_ANCHORS
EOF
    if [ -z "$problems" ]; then
        pass "S4: all 8 anchorable CPR sections carry their own body (CPR-WPH exempt — authored fresh, pinned by N3)"
    else
        fail "S4: section body mis-binding (body moved under the wrong heading?)$problems"
    fi
}
