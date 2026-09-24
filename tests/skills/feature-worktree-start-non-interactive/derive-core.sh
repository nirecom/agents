#!/bin/bash
# lang-check: ignore — intentional non-ASCII/CJK test fixture data (locale disambiguation / slugify robustness cases for issue #1910), not a comment-language violation
# tests/feature-worktree-start-non-interactive/derive-core.sh
# Tests: skills/worktree-start/scripts/derive-worktree-name.sh
# Tags: worktree, start, derivation, non-interactive, TL2, scope:issue-specific
# Behavioral cases B1-B7, B15, B20, B23 against
# skills/worktree-start/scripts/derive-worktree-name.sh.
# Part of the feature-worktree-start-non-interactive suite — see the dispatcher.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
setup_fixture

# --repo-dir is pinned to a remote-less fixture repo for every case in this file that
# does not itself target D4's gh label lookup (that path has its own dedicated coverage
# with a PATH-stubbed gh in derive-gh.sh). Without this pin, an invocation with no
# --repo-dir falls back to `git rev-parse --show-toplevel` of the suite's own CWD,
# which resolves to this real agents checkout — bin/is-github-dotcom-remote then exits
# 0 and D4 fires a LIVE, credentialed `gh issue view` against the real repo for
# whatever fixture issue number the case happens to use (rules/test/fixture-isolation.md
# "Neutral CWD and fixture project dir"). Reused across B1/B3/B7/B4's keyword table so
# the fixture repo is only created once.
CORE_REPO="$FIXTURE/core-repo"
mkdir -p "$CORE_REPO"
git -C "$CORE_REPO" init -q >/dev/null 2>&1
git -C "$CORE_REPO" config core.hooksPath /dev/null

# --- B1: issue-numbered task name from intent.md ---------------------------
run_derive B1 --intent "$INTENT_B1" --repo-dir "$CORE_REPO"
if [ "$RC" -eq 0 ] && has_line 'TASK_NAME=1910-worktree-start-task-name-branch' && has_line 'BRANCH_TYPE=feature'; then
    pass "B1: intent.md with issue number yields 1910-worktree-start-task-name-branch / feature"
else
    fail "B1: expected TASK_NAME=1910-worktree-start-task-name-branch + BRANCH_TYPE=feature (rc=$RC, out='$OUT')"
fi

# --- B2: NON_GITHUB — empty Issues section ---------------------------------
INTENT_B2="$FIXTURE/b2-intent.md"
write_intent "$INTENT_B2" "$TITLE_B1" ''
run_derive B2 --intent "$INTENT_B2"
if [ "$RC" -eq 0 ] && has_line 'TASK_NAME=worktree-start-task-name-branch'; then
    pass "B2: empty Issues section drops the leading issue number"
else
    fail "B2: expected TASK_NAME=worktree-start-task-name-branch (rc=$RC, out='$OUT')"
fi

# --- B3: all-Japanese title falls back to repo name, warns once ------------
INTENT_B3="$FIXTURE/b3-intent.md"
write_intent "$INTENT_B3" 'ワークツリー名を毎回聞かないでほしい' '- #77'
run_derive B3 --intent "$INTENT_B3" --repo-dir "$CORE_REPO"
B3_TN="$(task_name)"
B3_ERRLINES="$(printf '%s' "$ERR" | grep -c '[^[:space:]]')"
if [ "$RC" -eq 0 ] && printf '%s' "$B3_TN" | grep -qE '^77-[a-z0-9-]+$' && [ "$B3_ERRLINES" -eq 1 ]; then
    pass "B3: full-width title falls back to a non-empty slug and warns exactly once"
else
    fail "B3: expected rc=0, TASK_NAME ~ ^77-[a-z0-9-]+\$, 1 stderr line (rc=$RC, tn='$B3_TN', errlines=$B3_ERRLINES)"
fi

# --- B4: branch-type keyword table -----------------------------------------
# title-fragment | expected branch type
# Looped in the current shell (no pipeline subshell) so the B10 accumulator survives.
# $CORE_REPO pins the repo so D4's gh label lookup never fires (label arm lives in
# derive-gh.sh); without it each row would issue a live `gh issue view`.
# The last four rows pin word boundaries: an unanchored match would read "prefix"
# as fix, "documentary" as docs, "choreography" as chore.
B4_ROWS=(
    'Refactor the prompt files|refactor'
    'Update the docs for worktree|docs'
    'Routine chore for worktree naming|chore'
    'A boring prefix task|feature'
    'Fix login prefix bug|fix'
    'Write documentary about choreography|feature'
    'Document the choreography flow|docs'
    # Inflected forms — the other half of the word-boundary contract. A bare
    # whole-word match would read every one of these as `feature`, which is the
    # over-strict failure mode the bounded suffix list exists to prevent.
    'Fixes the parser|fix'
    'Refactoring the prompts|refactor'
    'Update documentation|docs'
    'Chores cleanup|chore'
    # …and the reject side of that same suffix rule: the list is closed, so a word that
    # merely starts with a keyword must still miss. An open `[a-z]*` suffix would read
    # both of these as fix.
    'Fixture setup for tests|feature'
    'Buggy legacy behavior|feature'
)
B4_IDX=0
for b4_row in "${B4_ROWS[@]}"; do
    b4_title="${b4_row%%|*}"
    b4_want="${b4_row##*|}"
    B4_IDX=$((B4_IDX + 1))
    # Indexed: several rows share an expected type, so the label and the fixture path
    # must not collide.
    b4_case="$B4_IDX-$b4_want"
    b4_intent="$FIXTURE/b4-$b4_case-intent.md"
    write_intent "$b4_intent" "$b4_title" '- #1910: keyword routing'
    run_derive "B4/$b4_case" --intent "$b4_intent" --repo-dir "$CORE_REPO"
    if [ "$RC" -eq 0 ] && has_line "BRANCH_TYPE=$b4_want"; then
        pass "B4/$b4_case: title '$b4_title' -> BRANCH_TYPE=$b4_want"
    else
        fail "B4/$b4_case: expected BRANCH_TYPE=$b4_want from title '$b4_title' (rc=$RC, out='$OUT')"
    fi
done

# --- B5: --headless label, no intent.md ------------------------------------
run_derive B5 --intent "$ABSENT_INTENT" --headless refactor-prompts
if [ "$RC" -eq 0 ] && printf '%s' "$(task_name)" | grep -qE "^refactor-prompts-$TS_RE\$" \
    && has_line 'BRANCH_TYPE=refactor'; then
    pass "B5: --headless refactor-prompts yields refactor-prompts-<utc-timestamp> / refactor"
else
    fail "B5: expected TASK_NAME=refactor-prompts-<14-digit UTC ts> + BRANCH_TYPE=refactor (rc=$RC, out='$OUT')"
fi

# --- B6: no intent.md and no --headless is a hard error --------------------
# The `-f $SCRIPT` guard keeps this case from passing vacuously on rc=127 while the
# script is still missing (a missing interpreter target also exits non-zero).
run_derive B6 --intent "$ABSENT_INTENT"
if [ -f "$SCRIPT" ] && [ "$RC" -ne 0 ] && ! printf '%s\n' "$OUT" | grep -q '^TASK_NAME=' && [ -n "$ERR" ]; then
    pass "B6: missing intent.md without --headless exits non-zero with a stderr diagnostic"
else
    fail "B6: expected rc!=0, no TASK_NAME on stdout, non-empty stderr (rc=$RC, out='$OUT', err='$ERR')"
fi

# --- B7: intent.md wins over --headless ------------------------------------
run_derive B7 --intent "$INTENT_B1" --headless something-else --repo-dir "$CORE_REPO"
B7_TN="$(task_name)"
if [ "$RC" -eq 0 ] && [ -n "$B7_TN" ] && ! printf '%s' "$B7_TN" | grep -qF 'something-else'; then
    pass "B7: intent.md takes precedence over --headless"
else
    fail "B7: expected an intent-derived TASK_NAME without 'something-else' (rc=$RC, tn='$B7_TN')"
fi

# --- B15 [C5b]: --headless is unconditionally non-interactive ---------------
# derive-worktree-name.sh never reads CONFIRM_WORKTREE; setting it to `on` must not
# change the output shape or introduce a prompt. run-with-timeout turns any hang into
# a failure instead of a stuck suite — the unit-level guarantee under TC9's WS-7
# headless pinning rule.
# Stdout contract is three lines since #1910: TASK_NAME=, BRANCH_TYPE=, REPO_NAME=.
# REPO_NAME comes from the running worktree, so the call is pinned to $AGENTS_DIR
# and the expectation derived the same way (correct in any checkout name).
B15_ERR="$FIXTURE/b15-stderr.txt"
B15_WANT_REPO="$(basename "$(git -C "$AGENTS_DIR" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$AGENTS_DIR")")"
B15_OUT="$(cd "$AGENTS_DIR" && CONFIRM_WORKTREE=on bash "$AGENTS_DIR/bin/run-with-timeout.sh" 20 \
    bash "$SCRIPT" --intent "$ABSENT_INTENT" --headless confirm-pinning-probe \
    2>"$B15_ERR" </dev/null)"
B15_RC=$?
B15_LINES="$(printf '%s\n' "$B15_OUT" | grep -c '[^[:space:]]')"
B15_RN="$(printf '%s\n' "$B15_OUT" | sed -n 's/^REPO_NAME=//p' | head -1)"
# safe_component()'s output domain: non-empty, not `.`/`..`, only [a-zA-Z0-9._-].
B15_RN_OK=0
case "$B15_RN" in
    ''|.|..) ;;
    *[!a-zA-Z0-9._-]*) ;;
    *) B15_RN_OK=1 ;;
esac
if [ "$B15_RC" -eq 0 ] && [ "$B15_LINES" -eq 3 ] \
    && printf '%s\n' "$B15_OUT" | grep -qE "^TASK_NAME=confirm-pinning-probe-$TS_RE\$" \
    && printf '%s\n' "$B15_OUT" | grep -qxF 'BRANCH_TYPE=feature' \
    && [ "$B15_RN_OK" -eq 1 ] && [ "$B15_RN" = "$B15_WANT_REPO" ] \
    && [ ! -s "$B15_ERR" ]; then
    pass "B15: --headless with CONFIRM_WORKTREE=on still emits exactly three lines (incl. a validated REPO_NAME), empty stderr, no prompt"
else
    fail "B15: expected rc=0, 3 stdout lines (confirm-pinning-probe-<ts> / feature / REPO_NAME=$B15_WANT_REPO), empty stderr (rc=$B15_RC, lines=$B15_LINES, repo_name='$B15_RN', out='$B15_OUT', err='$(cat "$B15_ERR")')"
fi

# --- B20 [N3]: D0 rejects an unusable repo-dir basename, and says how to fix it
# REPO_NAME becomes a filesystem path component, so safe_component() gates it exactly
# as D5 gates TASK_NAME (CPR-ORTH). A space is the cheapest character outside
# [a-zA-Z0-9._-]; the leading-character half of the same rule is table-covered in
# slugify-table.sh. Beyond the refusal itself, the diagnostic has to be actionable:
# the caller cannot rename a directory it was never told the constraint for.
B20_REPO="$FIXTURE/b20 repo"
mkdir -p "$B20_REPO"
run_derive B20 --intent "$ABSENT_INTENT" --headless d0-reject-probe --repo-dir "$B20_REPO"
if [ "$RC" -eq 1 ] && [ -z "$(task_name)" ] && [ -z "$(repo_name)" ] \
    && [[ "$ERR" == *'unusable as a path component'* ]]; then
    pass "B20: a repo-dir basename outside [a-zA-Z0-9._-] is refused at D0 (rc=1, nothing emitted)"
else
    fail "B20: expected rc=1 with the D0 path-component diagnostic and no emitted values (rc=$RC, out='$OUT', err='$ERR')"
fi
if [[ "$ERR" == *'[a-zA-Z0-9._-]'* && "$ERR" == *'must start with [a-zA-Z0-9]'* ]]; then
    pass "B20/constraint: the diagnostic states the character constraint it enforced"
else
    fail "B20/constraint: the diagnostic does not state the [a-zA-Z0-9._-] / leading-character constraint (err='$ERR')"
fi
if [[ "$ERR" == *'rename the checkout directory'* && "$ERR" == *'--repo-dir'* ]]; then
    pass "B20/remedy: the diagnostic offers both remedies (rename the checkout, or pass --repo-dir)"
else
    fail "B20/remedy: the diagnostic offers no actionable remedy (err='$ERR')"
fi
if [[ "$ERR" == *'b20 repo'* || "$OUT" == *'b20 repo'* ]]; then
    fail "B20/no-echo: the rejected directory name was echoed back (out='$OUT', err='$ERR')"
else
    pass "B20/no-echo: the rejected directory name is never echoed"
fi

# --- B23 [C4]: Windows-reserved device names, at BOTH validation points -----
# `CON`, `NUL`, `COM1`… are shape-valid under both path-component rules yet cannot
# exist as a directory on Windows, so a name that reaches `git worktree add` unchecked
# fails there instead — after the caller has already been told the path. Two validators
# own the two components of <base>/<TASK_NAME>/<REPO_NAME> and each carries its own
# guard and its own fixed diagnostic (CPR-ORTH): safe_component() at D0 for REPO_NAME,
# and the D5 output-validation block for TASK_NAME. Both are covered here, each with
# the sanctioned near-matches that must still be accepted — the match is exact and
# case-insensitive, so 'con-fix' and 'com10' are ordinary names.
B23_SAFE_MSG='safe_component: the value is a Windows-reserved device name (with or without an extension); rejecting it'
B23_TRAILING_DOT_MSG='safe_component: the value ends with a trailing dot, which Windows collapses/rejects; rejecting it'
B23_D5_MSG='derive-worktree-name: the derived task name is a Windows-reserved device name; refusing to emit it'

# REPO_NAME arm. The --repo-dir is deliberately NOT created: a directory named `CON`
# cannot be created on Windows at all, so materializing the reject rows and the accept
# rows the same way is impossible there. D0 falls back to the basename of --repo-dir
# when no git toplevel resolves, which gives every row one identical mechanism on every
# platform (CPR-UNV) with the basename as the only variable.
# label | --repo-dir basename | want rc
B23_REPO_ROWS=(
    'repo-CON|CON|1'
    'repo-NUL|NUL|1'
    'repo-COM1|COM1|1'
    # …and the same names carrying an extension. `CON.txt`, `NUL.log` and
    # `COM1.git` all resolve to the very same reserved device on Windows, so the
    # guard matches the pre-extension stem — a bare-name-only match would let
    # every one of these through to `git worktree add`.
    'repo-CON.txt|CON.txt|1'
    'repo-NUL.log|NUL.log|1'
    'repo-COM1.git|COM1.git|1'
    'repo-con-fix|con-fix|0'
    'repo-com10|com10|0'
)
for b23_row in "${B23_REPO_ROWS[@]}"; do
    IFS='|' read -r b23_label b23_base b23_rc <<< "$b23_row"
    run_derive "B23/$b23_label" --intent "$ABSENT_INTENT" --headless repo-reserved-probe \
        --repo-dir "$FIXTURE/b23-absent/$b23_base"
    if [ "$b23_rc" = "1" ]; then
        if [ "$RC" -eq 1 ] && [ -z "$(task_name)" ] && [ -z "$(repo_name)" ] \
            && printf '%s\n' "$ERR" | grep -qxF "$B23_SAFE_MSG" \
            && [[ "$ERR" == *'unusable as a path component'* ]]; then
            pass "B23/$b23_label: safe_component() refuses the reserved device name at D0 (rc=1, nothing emitted)"
        else
            fail "B23/$b23_label: expected rc=1, no TASK_NAME/REPO_NAME, and the safe_component reserved-name line (rc=$RC, out='$OUT', err='$ERR')"
        fi
        if [[ "$ERR" == *"$b23_base"* || "$OUT" == *"$b23_base"* ]]; then
            fail "B23/$b23_label/no-echo: the rejected directory name was echoed back (out='$OUT', err='$ERR')"
        else
            pass "B23/$b23_label/no-echo: the rejected directory name is never echoed"
        fi
    else
        if [ "$RC" -eq 0 ] && [ "$(repo_name)" = "$b23_base" ] \
            && printf '%s' "$(task_name)" | grep -qE "^repo-reserved-probe-$TS_RE\$" \
            && ! printf '%s\n' "$ERR" | grep -qxF "$B23_SAFE_MSG"; then
            pass "B23/$b23_label: the sanctioned near-match is accepted as REPO_NAME=$b23_base"
        else
            fail "B23/$b23_label: expected rc=0 with REPO_NAME=$b23_base and no reserved-name diagnostic (rc=$RC, out='$OUT', err='$ERR')"
        fi
    fi
done

# Trailing dot — safe_component()'s other D0-only guard, and a different one: Windows
# silently collapses a trailing dot off a path component, so the value is rejected
# before the reserved-name check is ever reached. Asserted outside B23_REPO_ROWS
# because the row loop pins the reserved-name line, which must NOT appear here — a
# safe_component reserved-name diagnostic would mean the wrong guard fired. Same
# present/absent message pairing the TASK_NAME arm below uses.
B23_DOT_BASE='somename.'
run_derive B23/repo-trailing-dot --intent "$ABSENT_INTENT" --headless repo-reserved-probe \
    --repo-dir "$FIXTURE/b23-absent/$B23_DOT_BASE"
if [ "$RC" -eq 1 ] && [ -z "$(task_name)" ] && [ -z "$(repo_name)" ] \
    && printf '%s\n' "$ERR" | grep -qxF "$B23_TRAILING_DOT_MSG" \
    && ! printf '%s\n' "$ERR" | grep -qxF "$B23_SAFE_MSG" \
    && [[ "$ERR" == *'unusable as a path component'* ]]; then
    pass "B23/repo-trailing-dot: safe_component() refuses a trailing-dot basename at D0 (rc=1, nothing emitted)"
else
    fail "B23/repo-trailing-dot: expected rc=1, no TASK_NAME/REPO_NAME, and the trailing-dot line alone (rc=$RC, out='$OUT', err='$ERR')"
fi
if [[ "$ERR" == *"$B23_DOT_BASE"* || "$OUT" == *"$B23_DOT_BASE"* ]]; then
    fail "B23/repo-trailing-dot/no-echo: the rejected directory name was echoed back (out='$OUT', err='$ERR')"
else
    pass "B23/repo-trailing-dot/no-echo: the rejected directory name is never echoed"
fi

# TASK_NAME arm. The title is the whole naming source (no issue number, no --headless
# disambiguator), so slugify(title) IS the derived TASK_NAME and D5 sees exactly the
# reserved token. $CORE_REPO keeps D4's gh lookup off the table, as everywhere else.
# No trailing-dot / name-plus-extension rows: slugify() collapses every non-[a-z0-9]
# run to '-' before D5, so 'CON.txt' arrives as 'con-txt' and D5's char class forbids
# dots outright — broader than D0's safe_component() pair, so CPR-ORTH holds without
# duplicating them here.
# label | intent title (== the derived TASK_NAME once slugified) | want rc
B23_TASK_ROWS=(
    'task-CON|CON|1'
    'task-NUL|NUL|1'
    'task-COM1|COM1|1'
    'task-con-fix|con-fix|0'
    'task-com10|com10|0'
)
for b23_row in "${B23_TASK_ROWS[@]}"; do
    IFS='|' read -r b23_label b23_title b23_rc <<< "$b23_row"
    b23_intent="$FIXTURE/b23-$b23_label-intent.md"
    write_intent "$b23_intent" "$b23_title" ''
    run_derive "B23/$b23_label" --intent "$b23_intent" --repo-dir "$CORE_REPO"
    if [ "$b23_rc" = "1" ]; then
        # The D5 line, not safe_component()'s: REPO_NAME is valid here, so a
        # safe_component diagnostic would mean the wrong validator fired.
        if [ "$RC" -eq 1 ] && [ -z "$(task_name)" ] \
            && printf '%s\n' "$ERR" | grep -qxF "$B23_D5_MSG" \
            && ! printf '%s\n' "$ERR" | grep -qxF "$B23_SAFE_MSG"; then
            pass "B23/$b23_label: D5 refuses the reserved device name as TASK_NAME (rc=1, nothing emitted)"
        else
            fail "B23/$b23_label: expected rc=1, no TASK_NAME, and the D5 reserved-name line alone (rc=$RC, out='$OUT', err='$ERR')"
        fi
        if [[ "$ERR" == *"$b23_title"* || "$OUT" == *"$b23_title"* ]]; then
            fail "B23/$b23_label/no-echo: the rejected task name was echoed back (out='$OUT', err='$ERR')"
        else
            pass "B23/$b23_label/no-echo: the rejected task name is never echoed"
        fi
    else
        if [ "$RC" -eq 0 ] && [ "$(task_name)" = "$b23_title" ] \
            && ! printf '%s\n' "$ERR" | grep -qxF "$B23_D5_MSG"; then
            pass "B23/$b23_label: the sanctioned near-match is accepted as TASK_NAME=$b23_title"
        else
            fail "B23/$b23_label: expected rc=0 with TASK_NAME=$b23_title and no reserved-name diagnostic (rc=$RC, out='$OUT', err='$ERR')"
        fi
    fi
done

report_shape core
finish
