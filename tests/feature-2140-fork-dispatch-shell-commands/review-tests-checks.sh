# tests/feature-2140-fork-dispatch-shell-commands/review-tests-checks.sh
# Tests: skills/review-tests/SKILL.md
# Tags: rules, prompt, dispatch, fork, scope:issue-specific, pwsh-not-required, TL2

# R1/R2: the new directive line must EXIST and sit strictly between the pre-existing Stop-guard
# Note line and RT-0 (top of `## Procedure`, before the first numbered step).
r2_ordering() { # <file> -> yes|no
    local f="$1" note_ln rt0_ln dir_ln
    note_ln="$(grep -n -m1 -F -- 'Note: the Stop-guard silence during dispatch is automatic' "$f" 2>/dev/null | cut -d: -f1)"
    rt0_ln="$(marker_lineno "$f" '^RT-0\.')"
    dir_ln="$(directive_lineno "$f")"
    [ -n "${note_ln:-}" ] && [ "$rt0_ln" != "0" ] && [ "$dir_ln" != "0" ] || { printf 'no'; return; }
    if [ "$dir_ln" -gt "$note_ln" ] && [ "$dir_ln" -lt "$rt0_ln" ]; then
        printf 'yes'
    else
        printf 'no'
    fi
}

# RT-2's block: from its own marker to the next RT-N marker (or EOF). Reused by R4/R5 and by
# G5/G7 in negative-controls.sh against fixtures.
rt2_block() { # <file> -> the RT-2 step body, or empty
    local f="$1" start rel end
    start="$(marker_lineno "$f" '^RT-2\.')"
    [ "$start" != "0" ] || return 0
    rel="$(tail -n +"$((start + 1))" "$f" | grep -n -m1 -E '^RT-[0-9]+[a-z]*\.' | cut -d: -f1)"
    if [ -n "$rel" ]; then end=$((start + rel)); else end="0"; fi
    range_block "$f" "$start" "$end"
}

# RT-2's reworded body must POINT AT rules/shell-commands.md's Tool Selection Priority while
# keeping its existing "via Write" mention -- on the SAME LINE, not merely both somewhere in the
# step. Two independent block-wide greps would accept "Do not use Write; ignore
# `rules/shell-commands.md`", which carries both tokens while inverting the directive; the
# same-line requirement plus the negation guard below close that.
RT2_NEGATION_RE='(do not|do n.t|don.t|never|no need to)([[:space:]]+[a-z]+){0,2}[[:space:]]+(use|call|invoke)[[:space:]]+(the[[:space:]]+)?.?Write|ignore[[:space:]]+[^.]*rules/shell-commands'

# (#2140/#2141 review finding C3): the negation guard above only catches an INVERTED directive
# ("do not use Write"); it never required RT-2 to actually PROHIBIT Bash, so permissive wording
# like "Write or Bash" -- which never inverts the Write mention -- passed through unchallenged.
# This requires an explicit anti-Bash phrase (do not/never/prohibited/not permitted) within a
# few words of the literal "Bash", on the same candidate line. The real RT-2 wording ("Do not
# substitute Bash-based assembly for the Write tool call") satisfies this directly.
RT2_ANTI_BASH_RE='(do not|do n.t|don.t|never|no need to|not permitted|prohibited)([[:space:]]+[A-Za-z]+){0,3}[[:space:]]+Bash'

# C4 fix (#2140/#2141 review cycle3 finding): `head -n1` inspected only the FIRST line
# matching both tokens, so a later, contradictory line in the same block (an inverted
# directive, or a permissive "Write or Bash" mention that never inverts Write but still
# authorizes Bash) was invisible to this classifier. Every matching line is now checked --
# any negation anywhere vetoes the block, any bare "Bash" mention not itself wrapped in the
# anti-Bash phrasing vetoes it too, and at least one line must carry the anti-Bash phrase.
rt2_mentions_write_and_rule() { # <rt2-block-text> -> yes|no
    local blk="$1" lines line anti_bash_found=no
    lines="$(printf '%s\n' "$blk" | grep -F -- 'rules/shell-commands.md' | grep -i -- 'Write')"
    [ -n "$lines" ] || { printf 'no'; return; }
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s\n' "$line" | grep -Eqi -- "$RT2_NEGATION_RE" && { printf 'no'; return; }
        printf '%s\n' "$line" | grep -Eqi -- "$RT2_ANTI_BASH_RE" && anti_bash_found=yes
    done <<RT2_CANDIDATE_LINES
$lines
RT2_CANDIDATE_LINES
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s\n' "$line" | grep -qi -- 'Bash' || continue
        printf '%s\n' "$line" | grep -Eqi -- "$RT2_ANTI_BASH_RE" || { printf 'no'; return; }
    done <<RT2_BLOCK_LINES
$blk
RT2_BLOCK_LINES
    [ "$anti_bash_found" = "yes" ] && printf 'yes' || printf 'no'
}

# GUARD: the reworded RT-2 must NOT re-enumerate concrete banned shell forms (no `cat`
# concatenation, no `<<`/`>>` literal enumeration) -- it points at the rule instead of
# reproducing rules/prompt.md 2.1's "no redundant hook examples" failure mode inline.
rt2_reenumerates_banned_forms() { # <rt2-block-text> -> yes|no
    local blk="$1"
    if printf '%s\n' "$blk" | grep -Eq -- '<<|>>|\bheredoc\b|\bcat\b|\bsed -i\b'; then
        printf 'yes'
    else
        printf 'no'
    fi
}

# R6 regression guard (review-security C1, HIGH): review-tests/SKILL.md now MANDATES reading
# rules/shell-commands.md's Command-Line Issuance Discipline (R1/R2 above) before the first Bash
# command -- so the file's own instructional text must not itself present the exact
# `VAR=$(...)` command-substitution form that rule prohibits on the Bash tool's own command
# line, or a fork-dispatched subagent could copy that literal syntax verbatim into a real Bash
# call, reproducing the #2140/#2141 incident from inside the very fix meant to prevent it.
skill_reintroduces_command_substitution() { # <file> -> yes|no
    local f="$1"
    [ -f "$f" ] || { printf 'no'; return; }
    if grep -qF -- '$(' "$f"; then printf 'yes'; else printf 'no'; fi
}

review_tests_checks() {
    assert_eq "R1: review-tests SKILL.md carries the top-of-Procedure shell-commands.md Read directive" \
        "yes" "$(directive_exists "$REVIEW_TESTS_SKILL")"
    assert_eq "R2: the directive sits after the Stop-guard Note and before RT-0 (top of Procedure)" \
        "yes" "$(r2_ordering "$REVIEW_TESTS_SKILL")"
    assert_eq "R3: RT-2's step marker still exists (RT step numbers are unchanged by this fix)" \
        "present" "$([ "$(marker_lineno "$REVIEW_TESTS_SKILL" '^RT-2\.')" != "0" ] && echo present || echo absent)"
    assert_eq "R4: RT-2's reworded body mentions both Write and rules/shell-commands.md" \
        "yes" "$(rt2_mentions_write_and_rule "$(rt2_block "$REVIEW_TESTS_SKILL")")"
    assert_eq "R5 GUARD: RT-2 does NOT re-enumerate concrete banned shell forms (points at the rule instead)" \
        "no" "$(rt2_reenumerates_banned_forms "$(rt2_block "$REVIEW_TESTS_SKILL")")"
    assert_eq "R6 GUARD (review-security C1): review-tests/SKILL.md never reintroduces a \$( command substitution in its own instructional text" \
        "no" "$(skill_reintroduces_command_substitution "$REVIEW_TESTS_SKILL")"
}

review_tests_checks
