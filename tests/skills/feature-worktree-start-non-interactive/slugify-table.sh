#!/bin/bash
# lang-check: ignore — intentional non-ASCII/CJK test fixture data (locale disambiguation / slugify robustness cases for issue #1910), not a comment-language violation
# tests/feature-worktree-start-non-interactive/slugify-table.sh
# Tests: skills/worktree-start/scripts/derive-worktree-name.sh
# Tags: worktree, start, slugify, table-driven, TL2, scope:issue-specific
# B14 — table-driven slugify / parsing contract for derive-worktree-name.sh.
# B24 — closes_issues[0] is the only issue number that names the worktree.
# Part of the feature-worktree-start-non-interactive suite — see the dispatcher.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
setup_fixture

# Repo used for the repo-name fallback row (slugify(title) empty -> basename of the
# --repo-dir toplevel). Its directory name IS the expected slug.
FALLBACK_REPO="$FIXTURE/wt-fallback-repo"
mkdir -p "$FALLBACK_REPO"
git -C "$FALLBACK_REPO" init -q >/dev/null 2>&1
git -C "$FALLBACK_REPO" config core.hooksPath /dev/null

B14_IDX=0
trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# name | mode | input | want TASK_NAME ({TS} = the D3b UTC disambiguator) | want BRANCH_TYPE | want rc
while IFS='|' read -r b14_name b14_mode b14_input b14_task b14_type b14_rc; do
    [[ -z "$b14_name" || "$b14_name" =~ ^[[:space:]]*# ]] && continue
    b14_name="${b14_name//[[:space:]]/}"
    b14_mode="${b14_mode//[[:space:]]/}"
    b14_task="${b14_task//[[:space:]]/}"
    b14_type="${b14_type//[[:space:]]/}"
    b14_rc="${b14_rc//[[:space:]]/}"
    b14_input="$(trim "$b14_input")"
    B14_IDX=$((B14_IDX + 1))

    case "$b14_mode" in
        headless)
            run_derive "B14/$b14_name" --intent "$ABSENT_INTENT" --headless "$b14_input" ;;
        intent)
            b14_intent="$FIXTURE/b14-$B14_IDX-intent.md"
            write_intent "$b14_intent" "$b14_input" ''
            run_derive "B14/$b14_name" --intent "$b14_intent" --repo-dir "$FALLBACK_REPO" ;;
        usage)
            run_derive "B14/$b14_name" "$b14_input" ;;
        repodir)
            # $input is the repo-directory BASENAME under test — D0 validates it with
            # safe_component() before anything else runs, so the naming source is a
            # constant --headless label and only the basename varies across rows.
            mkdir -p "$FIXTURE/repodir/$b14_input"
            run_derive "B14/$b14_name" --intent "$ABSENT_INTENT" --headless repo-probe \
                --repo-dir "$FIXTURE/repodir/$b14_input" ;;
        *)
            fail "B14/$b14_name: unknown table mode '$b14_mode'"; continue ;;
    esac

    assert_eq "B14/$b14_name/rc" "$b14_rc" "$RC"
    if [ -n "$b14_task" ]; then
        # A want carrying {TS} is compared as a regex — the disambiguator is a
        # wall-clock UTC timestamp and cannot be predicted exactly.
        if [[ "$b14_task" == *'{TS}'* ]]; then
            assert_match "B14/$b14_name/task" "^${b14_task//\{TS\}/$TS_RE}\$" "$(task_name)"
        else
            assert_eq "B14/$b14_name/task" "$b14_task" "$(task_name)"
        fi
    fi
    if [ -n "$b14_type" ]; then
        assert_eq "B14/$b14_name/type" "$b14_type" "$(branch_type)"
    fi
done <<'TABLE'
mixed-separators | headless | Mixed_Case  Title/With.Separators                | mixed-case-title-with-separators-{TS}  | feature | 0
token-cap-5      | headless | one two three four five six seven               | one-two-three-four-five-{TS}           | feature | 0
char-cap-40      | headless | abcdefghijklmnopqrstuvwxyz0123456789abcdefghi   | abcdefghijklmnopqrstuvwxyz0123456789abcd-{TS} | feature | 0
punctuation      | headless | !!!Hello,,,World???                             | hello-world-{TS}                       | feature | 0
empty-slug-label | headless | ！！！＠＠＠                                     | worktree-{TS}                          | feature | 0
repo-name-fallback | intent | ！！！＠＠＠                                     | wt-fallback-repo-{TS}                  | feature | 0
unknown-flag     | usage    | --bogus                                         |                                        |         | 64
# D0 safe_component() leading-character rule (symmetric with D5's TASK_NAME rule):
# the first character must be [a-zA-Z0-9]. A leading '-' reads as an option, a leading
# '.' as a dotfile, a leading '_' as neither — all three are refused outright rather
# than silently normalized. The two accepted rows are the boundary controls: a digit
# is a valid first character, and '.' / '-' remain legal in non-leading positions.
repodir-dot-only   | repodir | .                                             |                                        |         | 1
repodir-lead-dash  | repodir | -dash-repo                                  |                                        |         | 1
repodir-lead-under | repodir | _under-repo                                   |                                        |         | 1
repodir-lead-dot   | repodir | .dot-repo                                     |                                        |         | 1
repodir-lead-digit | repodir | 9digit-repo                                   | repo-probe-{TS}                        | feature | 0
repodir-inner-dot  | repodir | dot.mid-repo                                  | repo-probe-{TS}                        | feature | 0
TABLE

# --- B24 [C8]: closes_issues[0] is the only issue that names the worktree ----
# D2 resolves ISSUE as JSON.parse(ISSUE_JSON)[0]?.number and builds
# TASK_NAME="${ISSUE}-${SLUG}" from it, but a session may legitimately close several
# issues (1 session = N issues per rules/github-issues.md) and an intent.md is
# hand-edited, so a repeated reference is ordinary. Only the existing single-issue
# rows cover this today, which cannot distinguish "takes the first" from "takes the
# only one". Both a concatenation (100-200-…) and a silent switch to the second issue
# would produce a path and a branch that no longer trace to the session's lead issue.
#
# Ordering, not magnitude: the ascending and descending rows are the pair that proves
# the rule is insertion order rather than "lowest number wins".
# label | Issues-section body | want TASK_NAME
B24_TITLE='Multi issue naming source probe'
B24_SLUG='multi-issue-naming-source-probe'
B24_ROWS=(
    "ascending|- #100: first\n- #200: second|100-$B24_SLUG"
    "descending|- #200: first\n- #100: second|200-$B24_SLUG"
    "duplicate|- #100: first mention\n- #100: same issue again|100-$B24_SLUG"
    "cross-repo-second|- #100: local first\n- other-repo#200: cross-repo second|100-$B24_SLUG"
)
B24_IDX=0
for b24_row in "${B24_ROWS[@]}"; do
    IFS='|' read -r b24_label b24_body b24_want <<< "$b24_row"
    B24_IDX=$((B24_IDX + 1))
    b24_intent="$FIXTURE/b24-$B24_IDX-intent.md"
    # $FALLBACK_REPO is remote-less, so D4's gh label lookup can never fire for these
    # issue numbers (same reasoning as the table above).
    write_intent "$b24_intent" "$B24_TITLE" "$(printf '%b' "$b24_body")"
    run_derive "B24/$b24_label" --intent "$b24_intent" --repo-dir "$FALLBACK_REPO"
    assert_eq "B24/$b24_label/rc" "0" "$RC"
    assert_eq "B24/$b24_label/task: only the first parsed issue prefixes the task name" \
        "$b24_want" "$(task_name)"
done

# The exact-equality rows above already exclude a concatenation, but only implicitly.
# Pinned explicitly so the failure message says what actually went wrong: the second
# issue number must appear nowhere in the emitted name, and the first must appear once.
run_derive B24/no-second --intent "$FIXTURE/b24-1-intent.md" --repo-dir "$FALLBACK_REPO"
B24_TN="$(task_name)"
if [ -n "$B24_TN" ] && [[ "$B24_TN" != *'200'* ]]; then
    pass "B24/no-second: the second issue number never reaches the derived task name"
else
    fail "B24/no-second: '200' leaked into the derived task name (tn='$B24_TN')"
fi
B24_HITS="$(printf '%s' "$B24_TN" | grep -oF '100' | wc -l | tr -d ' ')"
assert_eq "B24/single-prefix: the first issue number appears exactly once (no 100-100 concatenation)" \
    "1" "$B24_HITS"

report_shape slugify
finish
