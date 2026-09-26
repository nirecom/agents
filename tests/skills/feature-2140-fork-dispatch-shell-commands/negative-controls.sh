# tests/feature-2140-fork-dispatch-shell-commands/negative-controls.sh
# Tests: skills/review-tests/SKILL.md, skills/refactor-prompts/SKILL.md
# Tags: rules, prompt, dispatch, fork, scope:issue-specific, pwsh-not-required, TL2

# G1-G13 -- NEGATIVE CONTROLS. R1-R5/F1-F4 alone cannot tell "the fix landed" apart from "the
# predicate lost the ability to say no", so every row below runs the SAME predicates over
# throwaway fixtures under $FIXROOT (never the real files): wrong place, wrong wording, wrong
# rule file, altered fence, re-enumerating RT-2, absent file, an unrelated sentence in
# refactor-prompts' prepend slot, three INVERTED directives (G10-G12 -- every token present,
# the order reversed), and the two fully-correct anti-vacuity fixtures (G7, G9). Each row's own
# assert_eq message states what it proves.

GOOD_DIRECTIVE='Read `rules/shell-commands.md` before the first Bash command, or before writing a file, per the fork-dispatch defensive measure.'
WRONG_FILE_DIRECTIVE='Read `rules/test.md` before the first Bash command, or before writing a file.'
MENTION_ONLY_LINE='See `rules/shell-commands.md` for the shell command rules that apply here.'
# refactor-prompts' step-2 prepend slot: an unrelated sentence (G8) vs the real directive (G9).
IRRELEVANT_PREPEND='Note: this step runs bash, so expect a short delay on cold caches.'
# GOOD_PREPEND/NEGATED_PREPEND carry BOTH triggers (#2140/#2141 review finding C5: the real fix
# line is "before the first Bash command, or before writing a file" -- refactor-prompts step 2
# does issue its own file write, the scratchpad script) so f1b's two-trigger check and the
# negation guard are both genuinely exercised, not incidentally satisfied by token absence.
GOOD_PREPEND='Read `rules/shell-commands.md` before the first Bash command, or before writing a file — defensive measure, same reasoning as review-tests.'
# G10-G12: the INVERTED directive. Each line below carries every token its predicate matches on
# while ordering the opposite, so a predicate without the negation guard cannot say no to it.
NEGATED_DIRECTIVE='Do not Read `rules/shell-commands.md` before the first Bash command, or before writing a file — it is already injected.'
NEGATED_PREPEND='Never Read `rules/shell-commands.md` before the first Bash command, or before writing a file; the fork inherits it.'
# G13: both lines in the slot. A whole-blob negation check would let the first veto the second.
MIXED_PREPEND="$NEGATED_PREPEND
$GOOD_PREPEND"
NEGATED_RT2_BODY='Do not use the Write tool here; ignore `rules/shell-commands.md` and assemble however is convenient.'
GOOD_RT2_BODY='Assemble review input via the Write tool only -- never Bash; see `rules/shell-commands.md` Tool Selection Priority for the banned shell forms and the scratchpad-script alternative.'
BANNED_RT2_BODY='Assemble review input via Write. Do NOT use `cat file1 file2 > combined` or a `<<EOF` heredoc; see `rules/shell-commands.md`.'
PLAIN_RT2_BODY='Concatenate test file(s) and source file(s) contents via Write.'
# G14 (#2140/#2141 review finding C3): permissive wording that names both Write and Bash without
# ever prohibiting Bash -- the old rt2_mentions_write_and_rule (negation-guard only) passed this.
PERMISSIVE_RT2_BODY='Assemble review input via Write or Bash; see `rules/shell-commands.md` for details.'
# G15 (#2140/#2141 review finding C4): every token the OLD step2_uses_scratchpad_pattern checked
# ("scratchpad script", "<PLANS_DIR>") is present, but split across lines with the read-back
# BEFORE the write/invoke/capture line, and missing the single-bash-call / stdout-capture /
# exact-session-file elements entirely -- the ordered-chain predicate must reject this.
CHAIN_OUT_OF_ORDER_BODY='   Read the scan output referenced by `<PLANS_DIR>` before running it.
   Write a scratchpad script that runs the scanner.'
# G16 (#2140/#2141 review finding C5): the two-trigger directive sits AFTER the scratchpad-
# creation action line instead of before it -- f1c must reject the reversed order.
REVERSED_ORDER_BODY='   Write a scratchpad script that runs `bash "$AGENTS_CONFIG_DIR/bin/refactor-prompts/index.sh"`.
   Read `rules/shell-commands.md` before the first Bash command, or before writing a file.'
# G17a (#2140/#2141 review cycle3 finding C4): every OLD vocabulary token is present, but the
# tool is renamed from "Write" to "Create" -- the strengthened chain check must reject this
# (the old check never required an affirmative "Write" mention at all).
NO_WRITE_MENTION_BODY='   Create a scratchpad script that runs `bash "$AGENTS_CONFIG_DIR/bin/refactor-prompts/index.sh"` and saves its stdout to `<PLANS_DIR>/<session-id>-refactor-prompts-scan.json`; invoke it as a single `bash <absolute-path>` call.
   Read the resulting file (Read tool) -- its content is the scan JSON for steps 3-6 below.'
# G17b (#2140/#2141 review cycle3 finding C4): the action line itself is untouched (still passes
# the chain check), but a heredoc-based rewrite is reintroduced a line below it -- the OLD check
# never scanned for banned heredoc (`<<`)/redirect (`>`) syntax anywhere else in the block.
HEREDOC_REINTRODUCED_BODY='   Write a scratchpad script that runs `bash "$AGENTS_CONFIG_DIR/bin/refactor-prompts/index.sh"` and saves its stdout to `<PLANS_DIR>/<session-id>-refactor-prompts-scan.json`; invoke it as a single `bash <absolute-path>` call.
   cat <<EOF > script.sh
   bash "$AGENTS_CONFIG_DIR/bin/refactor-prompts/index.sh" > scan.json
   EOF
   Read the resulting file (Read tool) -- its content is the scan JSON for steps 3-6 below.'

# G17c (#2140/#2141 review cycle3 finding C4, round-3 coverage gap): every action-chain
# vocabulary token is present on one line, but "write" itself is negated -- the strengthened
# chain check's own new negation branch (line_negates_verb ... 'write') must reject this, not
# just fall through to a false PASS via an untested code path.
NEGATED_WRITE_BODY='   Do not write a scratchpad script that runs `bash "$AGENTS_CONFIG_DIR/bin/refactor-prompts/index.sh"` and saves its stdout to `<PLANS_DIR>/<session-id>-refactor-prompts-scan.json`; invoke it as a single `bash <absolute-path>` call.
   Read the resulting file (Read tool) -- its content is the scan JSON for steps 3-6 below.'

# G18 (review-security C1, HIGH): a review-tests fixture whose RT-2 body reintroduces the exact
# `VAR=$(...)` command-substitution form -- the R6 regression guard must say "yes" (violation
# present), proving it can actually fail, not just vacuously pass the real (already-fixed) file.
COMMAND_SUBSTITUTION_RT2_BODY='TOKEN=$(node "$AGENTS_CONFIG_DIR/bin/compute-staged-tests-token.js" "${WORKTREE:-}")'

# GOOD_ACTION_LINE: the fixed step-2 wording (a scratchpad script, no command substitution on
# the Bash tool's own line). BUGGY_ACTION_LINE: the original #2140 bug pattern -- proves the F2
# regression guard in refactor-prompts-checks.sh still says yes to a reintroduced violation.
GOOD_ACTION_LINE='Write a scratchpad script that runs `bash "$AGENTS_CONFIG_DIR/bin/refactor-prompts/index.sh"` and saves its stdout to a file; invoke it as a single `bash <absolute-path>` call.'
BUGGY_ACTION_LINE='`SCAN_JSON=$(bash "$AGENTS_CONFIG_DIR/bin/refactor-prompts/index.sh")`'

# <path> <directive-text-or-empty> <position: before-rt0|after-rt0> <rt2-body-text>
make_review_tests_fixture() {
    local path="$1" dtext="$2" pos="$3" rt2body="$4"
    mkdir -p "$(dirname "$path")"
    {
        printf '%s\n' '---'
        printf '%s\n' 'name: review-tests'
        printf '%s\n' 'context: fork'
        printf '%s\n' '---'
        printf '%s\n' ''
        printf '%s\n' '## Procedure'
        printf '%s\n' ''
        printf '%s\n' 'Note: the Stop-guard silence during dispatch is automatic (PostToolUse marks the step `in_progress`). Do not emit `NEXT_STEP_PAUSE`.'
        [ -n "$dtext" ] && [ "$pos" = "before-rt0" ] && printf '%s\n' "$dtext"
        printf '%s\n' 'RT-0. Resolve the session-bound linked worktree path.'
        [ -n "$dtext" ] && [ "$pos" = "after-rt0" ] && printf '%s\n' "$dtext"
        printf '%s\n' 'RT-1. Identify staged test file(s) and source file(s).'
        printf '%s\n' 'RT-2. Assemble review input.'
        [ -n "$rt2body" ] && printf '  %s\n' "$rt2body"
        printf '%s\n' 'RT-3. Invoke the review loop.'
    } > "$path"
}

# <path> <action-line-text> [prepended-line-or-empty]
make_refactor_prompts_fixture() {
    local path="$1" action="$2" prepend="${3:-}"
    mkdir -p "$(dirname "$path")"
    {
        printf '%s\n' '---'
        printf '%s\n' 'name: refactor-prompts'
        printf '%s\n' 'context: fork'
        printf '%s\n' '---'
        printf '%s\n' ''
        printf '%s\n' '1. `/worktree-start --headless refactor-prompts`'
        printf '%s\n' '2. Resolve `<PLANS_DIR>` via `skills/_shared/resolve-plans-dir.md`.'
        [ -n "$prepend" ] && printf '   %s\n' "$prepend"
        printf '   %s\n' "$action"
        printf '%s\n' '   Abort with clear error if exit code is non-zero.'
    } > "$path"
}

# <path> <raw-multi-line-body> -- for G15/G16, whose fixtures need to control line order and
# content directly rather than fitting the prepend+single-action-line shape above.
make_refactor_prompts_body_fixture() { # <path> <body>
    local path="$1" body="$2"
    mkdir -p "$(dirname "$path")"
    {
        printf '%s\n' '---'
        printf '%s\n' 'name: refactor-prompts'
        printf '%s\n' 'context: fork'
        printf '%s\n' '---'
        printf '%s\n' ''
        printf '%s\n' '1. `/worktree-start --headless refactor-prompts`'
        printf '%s\n' '2. Resolve `<PLANS_DIR>` via `skills/_shared/resolve-plans-dir.md`.'
        printf '%s\n' "$body"
    } > "$path"
}

# The anti-vacuity row's combined verdict: every predicate must agree at once on one
# fully-correct fixture, or a single broken predicate could still report a false PASS elsewhere.
g7_all_check() { # <file> -> yes|no
    local f="$1" a b c d blk
    a="$(directive_exists "$f")"
    b="$(r2_ordering "$f")"
    blk="$(rt2_block "$f")"
    c="$(rt2_mentions_write_and_rule "$blk")"
    d="$(rt2_reenumerates_banned_forms "$blk")"
    if [ "$a" = "yes" ] && [ "$b" = "yes" ] && [ "$c" = "yes" ] && [ "$d" = "no" ]; then
        printf 'yes'
    else
        printf 'no'
    fi
}

negative_controls() {
    local f

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g1-after-rt0.md"
    make_review_tests_fixture "$f" "$GOOD_DIRECTIVE" "after-rt0" "$PLAIN_RT2_BODY"
    assert_eq "G1: a correctly-worded directive placed AFTER RT-0 fails the ordering check" \
        "no" "$(r2_ordering "$f")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g2-mention-only.md"
    make_review_tests_fixture "$f" "$MENTION_ONLY_LINE" "before-rt0" "$PLAIN_RT2_BODY"
    assert_eq "G2: a line naming the file without the Read/trigger wording is not the directive" \
        "no" "$(directive_exists "$f")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g3-wrong-file.md"
    make_review_tests_fixture "$f" "$WRONG_FILE_DIRECTIVE" "before-rt0" "$PLAIN_RT2_BODY"
    assert_eq "G3: a Read directive pointing at the WRONG rule file is not the directive" \
        "no" "$(directive_exists "$f")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g4-buggy-action-reintroduced.md"
    make_refactor_prompts_fixture "$f" "$BUGGY_ACTION_LINE"
    assert_eq "G4: the original #2140 bug pattern (command substitution) trips the F2 regression guard" \
        "yes" "$(step2_reintroduces_command_substitution "$f")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g5-banned-enum.md"
    make_review_tests_fixture "$f" "$GOOD_DIRECTIVE" "before-rt0" "$BANNED_RT2_BODY"
    assert_eq "G5: an RT-2 body that re-enumerates banned shell forms trips the guard" \
        "yes" "$(rt2_reenumerates_banned_forms "$(rt2_block "$f")")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g6-does-not-exist.md"
    assert_eq "G6: a missing file answers 'no' on both existence and ordering, without crashing" \
        "no:no" "$(directive_exists "$f"):$(r2_ordering "$f")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g8-irrelevant-prepend.md"
    make_refactor_prompts_fixture "$f" "$GOOD_ACTION_LINE" "$IRRELEVANT_PREPEND"
    assert_eq "G8: an unrelated sentence in step 2's prepend slot satisfies F1's position but fails F1b's content" \
        "yes:no" "$(f1_directive_precedes_action "$f"):$(f1b_prepended_line_is_the_directive "$f")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g9-good-prepend.md"
    make_refactor_prompts_fixture "$f" "$GOOD_ACTION_LINE" "$GOOD_PREPEND"
    assert_eq "G9 ANTI-VACUITY: the real directive in that slot passes F1, F1b, and the regression guard at once" \
        "yes:yes:no" "$(f1_directive_precedes_action "$f"):$(f1b_prepended_line_is_the_directive "$f"):$(step2_reintroduces_command_substitution "$f")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g10-negated-directive.md"
    make_review_tests_fixture "$f" "$NEGATED_DIRECTIVE" "before-rt0" "$PLAIN_RT2_BODY"
    assert_eq "G10: a line FORBIDDING the Read, in the right place with every trigger word, is not the directive" \
        "no" "$(directive_exists "$f")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g11-negated-prepend.md"
    make_refactor_prompts_fixture "$f" "$GOOD_ACTION_LINE" "$NEGATED_PREPEND"
    assert_eq "G11: a negated Read in step 2's prepend slot satisfies F1's position but fails F1b" \
        "yes:no" "$(f1_directive_precedes_action "$f"):$(f1b_prepended_line_is_the_directive "$f")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g13-mixed-prepend.md"
    make_refactor_prompts_fixture "$f" "$GOOD_ACTION_LINE" "$MIXED_PREPEND"
    assert_eq "G13: a negated line beside the real directive does not veto it (the verdict is per line)" \
        "yes:yes" "$(f1_directive_precedes_action "$f"):$(f1b_prepended_line_is_the_directive "$f")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g12-negated-rt2.md"
    make_review_tests_fixture "$f" "$GOOD_DIRECTIVE" "before-rt0" "$NEGATED_RT2_BODY"
    assert_eq "G12: an RT-2 body naming both Write and the rule while inverting both fails R4's check" \
        "no" "$(rt2_mentions_write_and_rule "$(rt2_block "$f")")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g7-fully-correct.md"
    make_review_tests_fixture "$f" "$GOOD_DIRECTIVE" "before-rt0" "$GOOD_RT2_BODY"
    assert_eq "G7 ANTI-VACUITY: a fully-correct fixture passes every check at once" \
        "yes" "$(g7_all_check "$f")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g14-permissive-write-or-bash.md"
    make_review_tests_fixture "$f" "$GOOD_DIRECTIVE" "before-rt0" "$PERMISSIVE_RT2_BODY"
    assert_eq "G14 (C3): 'Write or Bash' wording names both without prohibiting Bash and must fail" \
        "no" "$(rt2_mentions_write_and_rule "$(rt2_block "$f")")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g15-chain-out-of-order.md"
    make_refactor_prompts_body_fixture "$f" "$CHAIN_OUT_OF_ORDER_BODY"
    assert_eq "G15 (C4): tokens present but the read-back precedes the write/invoke/capture line, missing the ordered chain, fails F2b" \
        "no" "$(step2_uses_scratchpad_pattern "$f")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g16-directive-after-action.md"
    make_refactor_prompts_body_fixture "$f" "$REVERSED_ORDER_BODY"
    assert_eq "G16 (C5): the two-trigger directive sitting AFTER the scratchpad-creation action line fails the precedes-action check" \
        "no" "$(f1c_directive_precedes_action_by_lineno "$f")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g17a-no-write-mention.md"
    make_refactor_prompts_body_fixture "$f" "$NO_WRITE_MENTION_BODY"
    assert_eq "G17a (C4): renaming the tool mention from Write to Create fails the strengthened chain check" \
        "no" "$(step2_uses_scratchpad_pattern "$f")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g17b-heredoc-reintroduced.md"
    make_refactor_prompts_body_fixture "$f" "$HEREDOC_REINTRODUCED_BODY"
    assert_eq "G17b (C4): a heredoc/redirect rewrite reintroduced beside an intact action line trips the new regression guard" \
        "yes" "$(step2_reintroduces_heredoc_or_redirect "$f")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g17c-negated-write.md"
    make_refactor_prompts_body_fixture "$f" "$NEGATED_WRITE_BODY"
    assert_eq "G17c (C4): every action-chain token present but 'write' itself is negated fails the strengthened chain check" \
        "no" "$(step2_uses_scratchpad_pattern "$f")"

    ROWS=$((ROWS + 1))
    f="$FIXROOT/g18-command-substitution-reintroduced.md"
    make_review_tests_fixture "$f" "$GOOD_DIRECTIVE" "before-rt0" "$COMMAND_SUBSTITUTION_RT2_BODY"
    assert_eq "G18 (review-security C1): a reintroduced \$( command substitution trips the R6 regression guard" \
        "yes" "$(skill_reintroduces_command_substitution "$f")"
}

negative_controls
