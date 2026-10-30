# Today's bash wording of the edit-time hook and the commit-time gate, whole text.
# Sourced by tests/bin/feature-2411-gate-three-languages.sh. Green before and after #2411.
# shellcheck shell=bash

echo ""
echo "=== pin: block wording for bash tests ==="

PIN_MISSING_LINE="(2 paths in # Tests: header, no case_begin/case_end markers) code=MISSING_CASE_MARKERS"
PIN_GRAMMAR_LINE="line 4: malformed case marker (grammar) code=MALFORMED_CASE_MARKER"
PIN_DOC="skills/_shared/test-design/case-markers.md"
# pin_added_line <code-lines> — the S4-4b text for a bash new file whose cases cannot be counted.
pin_added_line() {
  printf '%s' "case added to a test file without valid case markers (case count unavailable: no case unit; code lines 0 -> $1); add case_begin/case_end to every case first, then each case's target is checked code=CASE_ADDED_WITHOUT_MARKERS"
}

REPO_MSG="$TMPBASE/repo-msg"
mkrepo "$REPO_MSG"

# pin_text <label> <got> <want>
pin_text() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1" "want [$3] got [$2]"
  fi
}

case_begin "pin-edit-time-block-text" "hooks/block-case-markers.js"
hook_write "$REPO_MSG" tests/hooks/new-missing.sh sh-missing
assert_eq "$HK_DECISION" "block"
# Both bodies are new files with two Tests: tokens and no conforming markers, so the edit-time
# reason also carries the #2502 S4-4b line (the language-match CLI runs only at edit time here).
pin_text "edit-time text, no markers" "$HK_REASON" "[block-case-markers] Test file(s) fail the test gates:
  tests/hooks/new-missing.sh: HIGH: tests/hooks/new-missing.sh $PIN_MISSING_LINE
  tests/hooks/new-missing.sh: HIGH: tests/hooks/new-missing.sh: $(pin_added_line 1)
Wrap each case in column-0 case_begin/case_end at depth 0 — see $PIN_DOC."
hook_write "$REPO_MSG" tests/hooks/new-grammar.sh sh-grammar
assert_eq "$HK_DECISION" "block"
pin_text "edit-time text, malformed marker" "$HK_REASON" "[block-case-markers] Test file(s) fail the test gates:
  tests/hooks/new-grammar.sh: HIGH: tests/hooks/new-grammar.sh $PIN_GRAMMAR_LINE
  tests/hooks/new-grammar.sh: HIGH: tests/hooks/new-grammar.sh: $(pin_added_line 2)
Wrap each case in column-0 case_begin/case_end at depth 0 — see $PIN_DOC."
hook_write "$REPO_MSG" tests/hooks/new-conforming.sh sh-conforming
assert_eq "$HK_DECISION" "approve"
case_end

case_begin "pin-commit-time-block-text" "hooks/pre-commit"
REPO_PC1="$TMPBASE/repo-pc-missing"
mkrepo "$REPO_PC1"
stage "$REPO_PC1" tests/hooks/new-missing.sh sh-missing
pc_run "$REPO_PC1"
assert_eq "$PC_RC" "1"
pin_text "commit-time text, no markers" "$PC_OUT" "HIGH: tests/hooks/new-missing.sh $PIN_MISSING_LINE

Commit blocked: new test file(s) fail the case-marker gate.
Wrap each case in case_begin/case_end (tests/lib/harness.sh)."
pin_text "commit-time stderr, no markers" "$PC_ERR" ""

REPO_PC2="$TMPBASE/repo-pc-grammar"
mkrepo "$REPO_PC2"
stage "$REPO_PC2" tests/hooks/new-grammar.sh sh-grammar
pc_run "$REPO_PC2"
assert_eq "$PC_RC" "1"
pin_text "commit-time text, malformed marker" "$PC_OUT" "HIGH: tests/hooks/new-grammar.sh $PIN_GRAMMAR_LINE

Commit blocked: new test file(s) fail the case-marker gate.
Fix marker placement — see $PIN_DOC."
pin_text "commit-time stderr, malformed marker" "$PC_ERR" ""

stage "$REPO_PC2" tests/bin/new-missing.sh sh-missing
pc_run "$REPO_PC2"
assert_eq "$PC_RC" "1"
pin_text "commit-time text, both causes" "$PC_OUT" "HIGH: tests/bin/new-missing.sh $PIN_MISSING_LINE
HIGH: tests/hooks/new-grammar.sh $PIN_GRAMMAR_LINE

Commit blocked: new test file(s) fail the case-marker gate.
Wrap each case in case_begin/case_end (tests/lib/harness.sh).
Fix marker placement — see $PIN_DOC."
case_end

# The self-implemented harness summary of the frontmatter gate (#2502): a new file and an existing
# file whose staged copy adds a counter the parent commit(s) lack both get the same two lines after
# the checker's (#2812 widened the baseline from HEAD to every parent).
PIN_SI_HEAD="Commit blocked: test file(s) add a self-implemented harness the parent commit(s) do not have."
PIN_SI_OLD="Commit blocked: new test file(s) build their own harness."
PIN_SI_LOAD="Load the language's helper library (tests/lib/harness.*) and use its counters and helpers instead."
PIN_SI_LINES=('#!/usr/bin/env bash' '# Tests: bin/a.sh' '# Tags: scope:common' 'source "$(dirname "$0")/../../tests/lib/harness.sh"' 'echo start')
# pin_si_run <repo> — the frontmatter gate (#2507: Node, via the runner) with <repo> as cwd.
# Sets PS_RC PS_OUT.
pin_si_run() {
  PS_RC=0
  (
    cd "$1" || exit 99
    "$PC_NODE" "$PC_RUNNER" tests-frontmatter frontmatter
  ) >"$TMPBASE/ps.out" 2>&1 || PS_RC=$?
  PS_OUT="$(cat "$TMPBASE/ps.out")"
}
# pin_si_check <label> — the summary after the checker's lines, whole text.
pin_si_check() {
  assert_eq "$1: rc=$PS_RC" "$1: rc=1"
  has "$1" "$PS_OUT" "code=SELF_IMPLEMENTED_HARNESS"
  pin_text "$1: summary" "${PS_OUT#*$'\n\n'}" "$PIN_SI_HEAD
$PIN_SI_LOAD"
  lacks "$1" "$PS_OUT" "$PIN_SI_OLD"
}

case_begin "pin-commit-time-self-impl-text" "hooks/pre-commit"
if [ ! -f "$SCRIPT_CHECKOUT_ROOT/hooks/pre-commit.d/checks/tests-frontmatter/frontmatter-gate.js" ]; then
  fail "self-impl summary" "frontmatter gate module not found"
else
  REPO_PS="$TMPBASE/repo-pc-self-impl"
  mkrepo "$REPO_PS"
  mkdir -p "$REPO_PS/bin"
  printf '\n' > "$REPO_PS/bin/a.sh"
  printf '%s\n' "${PIN_SI_LINES[@]}" > "$REPO_PS/tests/bin/existing.sh"
  git -C "$REPO_PS" add -A >/dev/null 2>&1
  git -C "$REPO_PS" commit -q -m existing >/dev/null 2>&1
  printf '%s\n' "${PIN_SI_LINES[@]}" 'PASS=0' > "$REPO_PS/tests/bin/newbad.sh"
  git -C "$REPO_PS" add -- tests/bin/newbad.sh >/dev/null 2>&1
  pin_si_run "$REPO_PS"
  pin_si_check "new self-impl file"
  git -C "$REPO_PS" rm -q --cached -- tests/bin/newbad.sh >/dev/null 2>&1
  printf '%s\n' "${PIN_SI_LINES[@]}" 'PASS=0' > "$REPO_PS/tests/bin/existing.sh"
  git -C "$REPO_PS" add -- tests/bin/existing.sh >/dev/null 2>&1
  pin_si_run "$REPO_PS"
  pin_si_check "existing file gains a counter"
fi
case_end

case_begin "pin-commit-time-pass-is-silent" "hooks/pre-commit"
REPO_PC3="$TMPBASE/repo-pc-ok"
mkrepo "$REPO_PC3"
stage "$REPO_PC3" tests/hooks/new-conforming.sh sh-conforming
pc_run "$REPO_PC3"
assert_eq "$PC_RC" "0"
pin_text "commit-time stdout on pass" "$PC_OUT" ""
pin_text "commit-time stderr on pass" "$PC_ERR" ""
case_end
