# shellcheck shell=bash
# tests/lib/read-directive-negation.sh
# Tests: tests/feature-2140-fork-dispatch-shell-commands.sh, tests/feature-2124-tool-selection-priority.sh
# Tags: rules, prompt, dispatch, library, scope:common, pwsh-not-required, TL2

# WHY (CPR-WPH): a line FORBIDDING a directive verb carries every token the "does this file ORDER
# it?" predicates match on, so without this guard they cannot say no to the inversion of the
# directive they pin. One guard for every dispatch-directive predicate across both suites
# (CPR-SSOT, CPR-ORTH): feature-2140-fork-dispatch-shell-commands.sh and
# feature-2124-tool-selection-priority/dispatch-timing.sh -- Read directives AND the A-layer
# "apply" directive alike, not just the verb the guard originally shipped for.
line_negates_verb() { # <line-or-lines> <verb> -> yes|no
    # Bounded to 3 intervening words ("do not ever bother to Read"), so an unrelated
    # "Do not substitute ..." earlier in a long line cannot negate the verb further along it.
    if printf '%s\n' "$1" \
        | grep -Eqi -- "(do not|do n.t|don.t|never|no need to|skip|avoid)([[:space:]]+[a-z']+){0,3}[[:space:]]+$2[[:space:]]"; then
        printf 'yes'
    else
        printf 'no'
    fi
}

line_negates_read() { # <line-or-lines> -> yes|no
    line_negates_verb "$1" 'Read'
}

# Callers filter a BLOCK down to candidate lines, so a negated line sitting beside a legitimate
# one must not veto it -- line_negates_verb alone would, since it greps the blob as a whole.
has_unnegated_line_verb() { # <candidate-lines> <verb> -> yes|no
    local ln verb="$2"
    while IFS= read -r ln; do
        [ -n "$ln" ] || continue
        [ "$(line_negates_verb "$ln" "$verb")" = "no" ] && { printf 'yes'; return; }
    done <<CANDIDATE_LINES
$1
CANDIDATE_LINES
    printf 'no'
}

has_unnegated_line() { # <candidate-lines> -> yes|no
    has_unnegated_line_verb "$1" 'Read'
}
