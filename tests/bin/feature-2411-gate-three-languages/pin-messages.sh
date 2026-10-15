# Today's bash wording of the edit-time hook and the commit-time gate, whole text.
# Sourced by tests/bin/feature-2411-gate-three-languages.sh. Green before and after #2411.
# shellcheck shell=bash

echo ""
echo "=== pin: block wording for bash tests ==="

PIN_MISSING_LINE="(2 paths in # Tests: header, no case_begin/case_end markers) code=MISSING_CASE_MARKERS"
PIN_GRAMMAR_LINE="line 4: malformed case marker (grammar) code=MALFORMED_CASE_MARKER"
PIN_DOC="skills/_shared/test-design/case-markers.md"

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
pin_text "edit-time text, no markers" "$HK_REASON" "[block-case-markers] New test file(s) fail the case-marker gate:
  tests/hooks/new-missing.sh: HIGH: tests/hooks/new-missing.sh $PIN_MISSING_LINE
Wrap each case in column-0 case_begin/case_end at depth 0 — see $PIN_DOC."
hook_write "$REPO_MSG" tests/hooks/new-grammar.sh sh-grammar
assert_eq "$HK_DECISION" "block"
pin_text "edit-time text, malformed marker" "$HK_REASON" "[block-case-markers] New test file(s) fail the case-marker gate:
  tests/hooks/new-grammar.sh: HIGH: tests/hooks/new-grammar.sh $PIN_GRAMMAR_LINE
Wrap each case in column-0 case_begin/case_end at depth 0 — see $PIN_DOC."
hook_write "$REPO_MSG" tests/hooks/new-conforming.sh sh-conforming
assert_eq "$HK_DECISION" "approve"
case_end

case_begin "pin-commit-time-block-text" "hooks/lib/precommit-tests-frontmatter.sh"
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

case_begin "pin-commit-time-pass-is-silent" "hooks/lib/precommit-tests-frontmatter.sh"
REPO_PC3="$TMPBASE/repo-pc-ok"
mkrepo "$REPO_PC3"
stage "$REPO_PC3" tests/hooks/new-conforming.sh sh-conforming
pc_run "$REPO_PC3"
assert_eq "$PC_RC" "0"
pin_text "commit-time stdout on pass" "$PC_OUT" ""
pin_text "commit-time stderr on pass" "$PC_ERR" ""
case_end
