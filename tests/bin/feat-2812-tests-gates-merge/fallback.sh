# Tests: hooks/pre-commit, bin/check-test-frontmatter.sh
# Tags: TL2, bin, hooks, pre-commit, merge, tests-gates, scope:issue-specific
# Fallbacks: when the merge parents cannot be decided (octopus, an unreadable MERGE_HEAD, a failing
# resolver, a malformed --merge-parents file) the gates judge against HEAD only and print the
# fallback note line once (D4); a criss-cross merge judges each H != M path against HEAD only (R7).
# Also the wiring: one parent resolution per commit across the three gates, and the frontmatter CLI
# honors a --merge-parents record file (D7).
# Sourced by tests/bin/feat-2812-tests-gates-merge-shapes.sh after bodies.sh (ex-*, c<N>-*).
# shellcheck shell=bash

echo ""
echo "=== fallback to HEAD only, and the parent-resolution wiring ==="

MP_LOG="$TMPBASE/merge-parents-calls.log"
# expect_fallback <label> — HEAD-only verdict on the MERGE_HEAD-only si.sh, plus exactly one note.
expect_fallback() {
  expect_rc "$1: judged against HEAD only" 1 "$GATE_RC" "$GATE_ALL"
  expect_codes "$1: si.sh is new against HEAD" "$GATE_OUT" SELF_IMPLEMENTED_HARNESS 1
  assert_eq "$1: fallback note lines=$(count_note "$GATE_ALL")" "$1: fallback note lines=1"
}
SI_UP="tests/bin/si.sh=ex-si"

case_begin "octopus-merge-falls-back-with-a-note" "hooks/pre-commit"
R="$TMPBASE/fb-octo"
raw fb-other '# other'
mkrepo "$R"
commit_all "$R" base
git -C "$R" checkout -q -b up
apply "$R" "$SI_UP"; commit_all "$R" up
git -C "$R" checkout -q -b up2 HEAD~1
apply "$R" "notes/o.txt=fb-other"; commit_all "$R" up2
git -C "$R" checkout -q -B work HEAD~1
printf 'head\n' > "$R/head.txt"; commit_all "$R" head
git -C "$R" merge --no-commit --no-ff -q up up2 >/dev/null 2>&1 || true
assert_eq "fixture fb-octo: MERGE_HEAD lines=$(wc -l < "$R/.git/MERGE_HEAD" 2>/dev/null | tr -d ' ')" \
  "fixture fb-octo: MERGE_HEAD lines=2"
gate "$R" "$FG"
expect_fallback "octopus"
case_end

case_begin "corrupt-merge-head-falls-back-with-a-note" "hooks/pre-commit"
R="$TMPBASE/fb-corrupt"
mergefx "$R" "" "$SI_UP" "" ""
printf '%s\n' 1234567890abcdef1234567890abcdef12345678 > "$R/.git/MERGE_HEAD"
gate "$R" "$FG"
expect_fallback "unreadable MERGE_HEAD"
case_end

case_begin "failing-merge-parents-resolver-falls-back-with-a-note" "hooks/pre-commit"
R="$TMPBASE/fb-clifail"
mergefx "$R" "" "$SI_UP" "" ""
export GATE_MP_MODE=fail
gate "$R" "$FG" "$CM" "$LG"
unset GATE_MP_MODE
expect_fallback "merge-parents resolver throws"
case_end

case_begin "criss-cross-judges-differing-parents-against-head-only" "hooks/pre-commit"
R="$TMPBASE/fb-criss"
crissfx "$R" "tests/bin/s.sh=c0-b" "tests/bin/s.sh=c1-m" "tests/bin/s.sh=c1-h" "tests/bin/s.sh=c2-hm"
gate "$R" "$FG"
expect_rc "criss-cross: H1 M1 staged 2, HEAD only" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "criss-cross: one counter beyond HEAD" "$GATE_OUT" SELF_IMPLEMENTED_HARNESS 1
case_end

case_begin "malformed-merge-parents-file-falls-back-with-a-note" "bin/check-test-frontmatter.sh"
R="$TMPBASE/fb-malformed"
mkrepo "$R"
apply "$R" "$SI_UP"
git -C "$R" add -A >/dev/null 2>&1
printf '%s\n' 'not a merge-parents record' > "$TMPBASE/garbage.mp"
cli "$R" "$FM_CLI" --staged --merge-parents "$TMPBASE/garbage.mp" tests/bin/si.sh
expect_rc "malformed --merge-parents: HEAD-only verdict" 1 "$CLI_RC" "$CLI_OUT $CLI_ERR"
expect_codes "malformed --merge-parents" "$CLI_OUT"$'\n'"$CLI_ERR" SELF_IMPLEMENTED_HARNESS 1
assert_eq "malformed --merge-parents: fallback note lines=$(count_note "$CLI_OUT"$'\n'"$CLI_ERR")" \
  "malformed --merge-parents: fallback note lines=1"
case_end

case_begin "one-merge-parents-resolution-per-commit" "hooks/pre-commit"
R="$TMPBASE/fb-once"
mergefx "$R" "" "$SI_UP tests/bin/nomark.sh=ex-nomark" "" ""
: > "$MP_LOG"
export GATE_MP_MODE=log GATE_MP_LOG="$MP_LOG"
gate "$R" "$FG" "$CM" "$LG"
unset GATE_MP_MODE GATE_MP_LOG
n=0
while IFS= read -r _l; do [ -n "$_l" ] && n=$((n + 1)); done < "$MP_LOG"
assert_eq "merge-parents resolutions across three gates=$n" "merge-parents resolutions across three gates=1"
case_end

# The frontmatter CLI takes the bin/merge-parents record stream as --merge-parents <file>: si.sh,
# staged equal to MERGE_HEAD, is an existing file (no block); without the flag the CLI resolves the
# parents itself and reaches the same verdict.
case_begin "frontmatter-cli-honors-a-merge-parents-file" "bin/check-test-frontmatter.sh"
R="$TMPBASE/fb-wire"
mergefx "$R" "" "$SI_UP" "" ""
MP_FILE="$TMPBASE/fb-wire.mp"
( cd "$R" && printf 'tests/bin/si.sh\0' | bash "$RWT" 90 node "$GATE_CFG/bin/merge-parents" ) >"$MP_FILE" 2>/dev/null \
  || fail "fb-wire" "bin/merge-parents failed"
cli "$R" "$FM_CLI" --staged --merge-parents "$MP_FILE" tests/bin/si.sh
expect_rc "--merge-parents file: MERGE_HEAD file is existing" 0 "$CLI_RC" "$CLI_OUT $CLI_ERR"
expect_codes "--merge-parents file" "$CLI_OUT"$'\n'"$CLI_ERR" SELF_IMPLEMENTED_HARNESS 0
cli "$R" "$FM_CLI" --staged tests/bin/si.sh
expect_rc "no --merge-parents: the CLI resolves the parents itself" 0 "$CLI_RC" "$CLI_OUT $CLI_ERR"
expect_codes "no --merge-parents" "$CLI_OUT"$'\n'"$CLI_ERR" SELF_IMPLEMENTED_HARNESS 0
case_end
