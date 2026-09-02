# tests/feature-2140-fork-dispatch-shell-commands/refactor-prompts-checks.sh
# Tests: skills/refactor-prompts/SKILL.md
# Tags: rules, prompt, dispatch, fork, scope:issue-specific, pwsh-not-required, TL2

# The fix (#2140 follow-up, finding C/#1) replaced step 2's fenced `SCAN_JSON=$(bash ...)`
# command substitution -- itself the Command-Line Issuance Discipline violation -- with a
# scratchpad-script + <PLANS_DIR>-file capture. No fence exists in the file anymore, so these
# checks anchor on the action line's own text (present in both the fixed and buggy wording,
# since both reference `refactor-prompts/index.sh`) instead of a fence delimiter.

# The step-2 body: every line from just after step 2's own numbered line up to (not including)
# step 3, or EOF if step 3 is absent (fixtures below never add a step 3).
step2_block() { # <file> -> content, or empty
    local f="$1" step2_ln step3_ln
    step2_ln="$(marker_lineno "$f" '^2\. ')"
    [ "$step2_ln" != "0" ] || return 0
    step3_ln="$(marker_lineno "$f" '^3\. ')"
    range_block "$f" "$((step2_ln + 1))" "$step3_ln"
}

# The action line's position: the first line at or after step 2 that names the scanner script.
# Both GOOD_ACTION_LINE and BUGGY_ACTION_LINE carry this substring, so this anchor is agnostic
# to which wording is under test -- only F2 / F2b below tell the two apart.
step2_action_lineno() { # <file> -> 1-based lineno, or 0
    local f="$1" step2_ln rel
    step2_ln="$(marker_lineno "$f" '^2\. ')"
    [ "$step2_ln" != "0" ] || { printf '0'; return; }
    rel="$(tail -n +"$((step2_ln + 1))" "$f" 2>/dev/null | grep -n -m1 -F -- 'refactor-prompts/index.sh' | cut -d: -f1)"
    if [ -n "$rel" ]; then printf '%s' "$((step2_ln + rel))"; else printf '0'; fi
}

# F1: at least one new prose line sits between step 2's own numbered line and the action line --
# today the action line follows immediately (gap of 1); the fix prepends a sentence ahead of it
# (gap of 2+), never merged into the existing line (prompt.md 1.2).
f1_directive_precedes_action() { # <file> -> yes|no
    local f="$1" step2_ln action_ln
    step2_ln="$(marker_lineno "$f" '^2\. ')"
    [ "$step2_ln" != "0" ] || { printf 'no'; return; }
    action_ln="$(step2_action_lineno "$f")"
    [ "$action_ln" != "0" ] || { printf 'no'; return; }
    if [ "$((action_ln - step2_ln))" -ge 2 ]; then printf 'yes'; else printf 'no'; fi
}

# F1b: the prepended line must BE the Read directive, not merely occupy the slot. F1 alone
# checks position, so any unrelated sentence landing there would pass it while missing the fix
# entirely -- this is refactor-prompts' counterpart to review-tests' R4 content check.
# (#2140/#2141 review finding C5): refactor-prompts' step 2 DOES issue a file write of its own
# (the scratchpad script, created via the Write tool) -- the old justification here claiming
# otherwise was factually wrong. The real fix line ("before the first Bash command, or before
# writing a file") carries the SAME two-trigger contract as the dispatcher's directive_lineno()
# in tests/feature-2140-fork-dispatch-shell-commands.sh, so both triggers are required here too.
f1b_prepended_line_is_the_directive() { # <file> -> yes|no
    local f="$1" step2_ln action_ln blk
    step2_ln="$(marker_lineno "$f" '^2\. ')"
    [ "$step2_ln" != "0" ] || { printf 'no'; return; }
    action_ln="$(step2_action_lineno "$f")"
    [ "$action_ln" != "0" ] || { printf 'no'; return; }
    blk="$(printf '%s\n' "$(range_block "$f" "$((step2_ln + 1))" "$action_ln")" \
        | grep -F -- 'rules/shell-commands.md' \
        | grep -F -- 'Read' \
        | grep -Ei -- 'before (the )?(first )?Bash command' \
        | grep -Ei -- 'before (writing|you write|it writes|any (file )?write|creating or writing)')"
    [ -n "$blk" ] || { printf 'no'; return; }
    # A line that FORBIDS the Read carries the same tokens, and the slot may hold several
    # candidates -- so the verdict is per line (tests/lib/read-directive-negation.sh).
    printf '%s' "$(has_unnegated_line "$blk")"
}

# F1c (#2140/#2141 review finding C5): proves ORDER, not just presence -- the directive's own
# line number (found the same way, mirrored from directive_lineno() in the parent test file)
# must sit strictly BEFORE the scratchpad-creation action line, not merely somewhere in the
# prepend slot. Reuses step2_action_lineno() as the reference point.
f1c_directive_lineno_in_slot() { # <file> -> 1-based lineno, or 0
    local f="$1" step2_ln action_ln hit rel
    step2_ln="$(marker_lineno "$f" '^2\. ')"
    [ "$step2_ln" != "0" ] || { printf '0'; return; }
    action_ln="$(step2_action_lineno "$f")"
    [ "$action_ln" != "0" ] || { printf '0'; return; }
    hit="$(range_block "$f" "$((step2_ln + 1))" "$action_ln" \
        | grep -n -F -- 'rules/shell-commands.md' \
        | grep -F -- 'Read' \
        | grep -Ei -- 'before (the )?(first )?Bash command' \
        | grep -Ei -- 'before (writing|you write|it writes|any (file )?write|creating or writing)' \
        | head -n1)"
    [ -n "$hit" ] || { printf '0'; return; }
    rel="${hit%%:*}"
    printf '%s' "$((step2_ln + rel))"
}

f1c_directive_precedes_action_by_lineno() { # <file> -> yes|no
    local f="$1" d a
    d="$(f1c_directive_lineno_in_slot "$f")"
    [ "$d" != "0" ] || { printf 'no'; return; }
    a="$(step2_action_lineno "$f")"
    [ "$a" != "0" ] || { printf 'no'; return; }
    if [ "$d" -lt "$a" ]; then printf 'yes'; else printf 'no'; fi
}

# F2 regression guard (replaces the old byte-identity pin, which had pinned the #2140 BUG's own
# text as a required "unchanged invariant"): step 2 must never again issue a literal `$(`
# command substitution -- the exact pattern rules/shell-commands.md's Command-Line Issuance
# Discipline prohibits on the Bash tool's own command line.
step2_reintroduces_command_substitution() { # <file> -> yes|no
    local f="$1" blk
    blk="$(step2_block "$f")"
    if printf '%s\n' "$blk" | grep -qF -- '$('; then printf 'yes'; else printf 'no'; fi
}

# F2b positive replacement (#2140/#2141 review finding C4): two independent substring checks
# ("scratchpad script" / "<PLANS_DIR>" present ANYWHERE in the block) cannot tell the real
# ordered data-flow chain apart from the tokens sitting in the wrong order or split across
# unrelated sentences. The actual chain step 2 describes: create the script via Write -> invoke
# it as a single `bash <absolute-path>` call -> save its stdout to the EXACT session file
# (`<PLANS_DIR>/<session-id>-refactor-prompts-scan.json`) -> read that file (Read tool) before
# steps 3-6. The first four elements land on ONE line in the real file; the read-back is a
# LATER line. This checks both: all creation/invocation/capture tokens co-occur on one line, and
# a read-back line (naming the session file, or referencing "steps 3-6") sits strictly after it.
SESSION_FILE_TOKEN='<PLANS_DIR>/<session-id>-refactor-prompts-scan.json'

# NOTE: combining -F (fixed-string) with -i (case-insensitive) on a line containing multibyte
# UTF-8 (these SKILL.md files carry em/en dashes) crashes GNU grep 3.0 (SIGABRT) on this host.
# None of the literals below contain BRE metacharacters, so plain `grep -i` (no -F) is used
# wherever case-insensitivity is needed; `grep -F` alone (no -i) is safe and used where the
# token's case is fixed (`<absolute-path>`, the exact session-file path).
step2_action_chain_lineno() { # <block-text> -> 1-based lineno within block, or 0
    local blk="$1" n
    n="$(printf '%s\n' "$blk" | grep -n -i -- 'scratchpad script' \
        | grep -i -- 'bash' \
        | grep -i -- 'single' \
        | grep -F -- '<absolute-path>' \
        | grep -i -- 'stdout' \
        | grep -F -- "$SESSION_FILE_TOKEN" \
        | head -n1 | cut -d: -f1)"
    printf '%s' "${n:-0}"
}

step2_read_back_lineno() { # <block-text> -> 1-based lineno within block, or 0
    local blk="$1" n
    n="$(printf '%s\n' "$blk" | grep -n -i -- 'Read' \
        | grep -F -- "$SESSION_FILE_TOKEN" \
        | head -n1 | cut -d: -f1)"
    if [ -z "$n" ]; then
        n="$(printf '%s\n' "$blk" | grep -n -i -- 'Read' \
            | grep -Ei -- 'steps?[[:space:]]*3(-|–| through | to )6' \
            | head -n1 | cut -d: -f1)"
    fi
    printf '%s' "${n:-0}"
}

step2_uses_scratchpad_pattern() { # <file> -> yes|no
    local f="$1" blk action_ln read_ln
    blk="$(step2_block "$f")"
    [ -n "$blk" ] || { printf 'no'; return; }
    action_ln="$(step2_action_chain_lineno "$blk")"
    [ "$action_ln" != "0" ] || { printf 'no'; return; }
    read_ln="$(step2_read_back_lineno "$blk")"
    [ "$read_ln" != "0" ] || { printf 'no'; return; }
    if [ "$read_ln" -gt "$action_ln" ]; then printf 'yes'; else printf 'no'; fi
}

refactor_prompts_checks() {
    assert_eq "F1: step 2 gains a prepended sentence before its action line" \
        "yes" "$(f1_directive_precedes_action "$REFACTOR_PROMPTS_SKILL")"
    assert_eq "F1b: that prepended line IS the shell-commands.md Read directive, not any sentence" \
        "yes" "$(f1b_prepended_line_is_the_directive "$REFACTOR_PROMPTS_SKILL")"
    assert_eq "F1c: the directive line's own line number precedes the scratchpad-creation action line" \
        "yes" "$(f1c_directive_precedes_action_by_lineno "$REFACTOR_PROMPTS_SKILL")"
    assert_eq "F2: step 2 never reintroduces a \$( command substitution (regression guard, not a byte-identity pin)" \
        "no" "$(step2_reintroduces_command_substitution "$REFACTOR_PROMPTS_SKILL")"
    assert_eq "F2b: step 2 documents the scratchpad-script + <PLANS_DIR>-file capture pattern" \
        "yes" "$(step2_uses_scratchpad_pattern "$REFACTOR_PROMPTS_SKILL")"
    assert_eq "F3: review-tests/SKILL.md declares context: fork" \
        "yes" "$(frontmatter_has_context_fork "$REVIEW_TESTS_SKILL")"
    assert_eq "F4: refactor-prompts/SKILL.md declares context: fork" \
        "yes" "$(frontmatter_has_context_fork "$REFACTOR_PROMPTS_SKILL")"
}

refactor_prompts_checks
