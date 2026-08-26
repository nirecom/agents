#!/bin/bash
# tests/feature-2099-complexity-stage-routing/skip-boolean-guard-cases.sh
# Tests: bin/workflow/record-complexity-and-skip, hooks/workflow-state/skip-signal-resolver.js, hooks/workflow-state/skip-signal-resolver/complexity.js, skills/clarify-intent/SKILL.md, skills/workflow-init/SKILL.md
# Tags: complexity, routing, skip-dispatch, cli, boolean, arg-parsing, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.

# Why: --so-c1/--so-c2 carry the caller's OWN judgment that the outline skip does
# not apply, outranking the complexity-derived auto branch. What counts as "the
# caller said no" was pinned nowhere before this file.

# One --advance invocation as "<rc> <SKIP_MODE> <SKIP_DISPATCH>". Zero signals
# throughout, so the internal SKIP_MODE is `auto` and the guard is the only
# thing that can change the dispatch.
d2099bg_dispatch() {
    local sid="$1"; shift
    local out rc=0 mode disp
    out=$(run_with_timeout bash "$BIN_RECORD_SKIP" --session "$sid" --signals "" \
        --target outline --advance "$@" 2>/dev/null) || rc=$?
    mode=$(printf '%s\n' "$out" | grep -m1 '^SKIP_MODE=' | cut -d= -f2-)
    disp=$(printf '%s\n' "$out" | grep -m1 '^SKIP_DISPATCH=' | cut -d= -f2-)
    printf '%s %s %s' "$rc" "${mode:-NONE}" "${disp:-NONE}"
}

# BG-1: the documented vocabulary, on BOTH flags (CPR-ORTH — a guard that read
# only so_c1 would pass every so_c1 row and silently ignore the other flag).
d2099bg_documented_vocabulary() {
    local out="" label
    for label in c1-false c2-false both-false both-true; do
        case "$label" in
            c1-false)   out="$out$label -> $(d2099bg_dispatch "$(new_session bg1)" --so-c1 false --so-c2 true)" ;;
            c2-false)   out="$out$label -> $(d2099bg_dispatch "$(new_session bg2)" --so-c1 true --so-c2 false)" ;;
            both-false) out="$out$label -> $(d2099bg_dispatch "$(new_session bg3)" --so-c1 false --so-c2 false)" ;;
            both-true)  out="$out$label -> $(d2099bg_dispatch "$(new_session bg4)" --so-c1 true --so-c2 true)" ;;
        esac
        out="$out"$'\n'
    done
    assert_block "BG-1 an explicit false on EITHER flag outranks the auto branch; true/true lets it advance" \
        "$(printf '%s' "$out")" <<'EOF'
c1-false -> 0 auto no-skip
c2-false -> 0 auto no-skip
both-false -> 0 auto no-skip
both-true -> 0 auto advanced
EOF
}

# BG-2: the guard is scoped to --advance. Without it the wrapper speaks the
# legacy `auto`/`judgment` protocol and prints no SKIP_DISPATCH at all, so a
# caller cannot suppress the skip through these flags on that path.
d2099bg_guard_is_advance_scoped() {
    local sid out
    sid=$(new_session bg-legacy)
    out=$(run_with_timeout bash "$BIN_RECORD_SKIP" --session "$sid" --signals "" \
        --target outline --so-c1 false --so-c2 false 2>/dev/null)
    assert_eq "BG-2 without --advance the wrapper still answers the legacy auto/judgment protocol" \
        "auto" "$out"
    assert_not_contains "BG-3 ... and prints no SKIP_DISPATCH line off the advance path" \
        "SKIP_DISPATCH" "$out"
}

# BG-4: a flag with NO value. Under `set -u` reading "$2" blindly would either
# crash or swallow the following flag as this flag's value; both must be usage
# errors (exit 2) rather than a value the guard then compares.
d2099bg_missing_value_is_usage_error() {
    local sid rc out
    sid=$(new_session bg-noval)

    rc=0
    out=$(run_with_timeout bash "$BIN_RECORD_SKIP" --session "$sid" --signals "" \
        --target outline --advance --so-c1 2>&1) || rc=$?
    assert_eq "BG-4 a trailing --so-c1 is a usage error (exit 2), not an empty value" "2" "$rc"
    assert_contains "BG-5 ... named as a --so-c1 usage error rather than a shell crash" \
        "--so-c1 requires a value" "$out"

    rc=0
    out=$(run_with_timeout bash "$BIN_RECORD_SKIP" --session "$sid" --signals "" \
        --target outline --advance --so-c1 --so-c2 true 2>&1) || rc=$?
    assert_eq "BG-6 --so-c1 never swallows the following flag as its value (exit 2)" "2" "$rc"
    assert_contains "BG-7 ... and says so about --so-c1" "--so-c1 requires a value" "$out"

    rc=0
    out=$(run_with_timeout bash "$BIN_RECORD_SKIP" --session "$sid" --signals "" \
        --target outline --advance --so-c2 2>&1) || rc=$?
    assert_eq "BG-8 the symmetric --so-c2 case is rejected identically (exit 2)" "2" "$rc"
    assert_contains "BG-9 ... naming --so-c2" "--so-c2 requires a value" "$out"

    # Teeth: a rejected invocation must leave no evaluation behind, or the
    # "rejected" rows above would be indistinguishable from a partial run.
    assert_eq "BG-10 ... and a rejected invocation records no complexity evaluation" \
        "NONE" "$(run_with_timeout node "$BIN_READ" --session "$sid" --stage detail 2>/dev/null | head -1)"
}

# BG-11: --target, parsed by the SAME while-loop, DOES validate its vocabulary.
# It is the sibling that makes the so_c1/so_c2 gap below a real asymmetry rather
# than a house style of trusting every flag value.
d2099bg_sibling_flag_validates_its_vocabulary() {
    local sid rc out
    sid=$(new_session bg-target)
    rc=0
    out=$(run_with_timeout bash "$BIN_RECORD_SKIP" --session "$sid" --signals "" \
        --target Outline --advance 2>&1) || rc=$?
    assert_eq "BG-11 --target rejects a value outside its documented vocabulary (exit 2)" "2" "$rc"
    assert_contains "BG-12 ... naming the vocabulary it expected" \
        "--target must be 'outline' or 'detail'" "$out"
}

# BG-13..BG-15: the malformed-boolean scenarios, deliberately NOT asserted. The
# guard compares against the literal `false` and validates nothing else, so a
# typo falls through to the auto branch and the outline step is skipped although
# the caller meant the opposite. Pinning that would freeze a fail-UNSAFE default;
# it is reported as a source gap instead (rules/test.md Pattern 3).
d2099bg_malformed_boolean_gap() {
    skip "BG-13 SOURCE GAP: a non-boolean --so-c1/--so-c2 value (fasle/False/0/no/empty/trailing-space) does not match the literal \`false\`, so the guard silently falls through to the auto-skip branch"
    skip "BG-14 SOURCE GAP: conflicting duplicate flags (--so-c1 false --so-c1 true) resolve last-occurrence-wins, discarding an explicit no-skip judgment without diagnosis"
    skip "BG-15 SOURCE GAP: --so-c1/--so-c2 accept any string while their sibling --target (BG-11) rejects one outside its vocabulary — same parser, opposite strictness (CPR-ORTH)"
}

d2099bg_documented_vocabulary
d2099bg_guard_is_advance_scoped
d2099bg_missing_value_is_usage_error
d2099bg_sibling_flag_validates_its_vocabulary
d2099bg_malformed_boolean_gap
