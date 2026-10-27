# Tests: bin/lib/merge-parents.sh, hooks/lib/precommit-tests-frontmatter.sh, bin/check-test-frontmatter.sh
# Tags: TL2, bin, hooks, pre-commit, merge, tests-gates, scope:issue-specific
# Fallbacks: when the merge parents cannot be decided (octopus, an unreadable MERGE_HEAD, a failing
# CLI, a malformed --merge-parents file) the gates judge against HEAD only and print the mp_note line
# once (D4); a criss-cross merge judges each H != M path against HEAD only (R7). Also the wiring:
# one CLI call per commit, and the frontmatter CLI receives --merge-parents (D7).
# Sourced by tests/bin/feat-2812-tests-gates-merge-shapes.sh after bodies.sh (ex-*, c<N>-*).
# shellcheck shell=bash
# shellcheck disable=SC2016 # shim lines hold literal $ text on purpose

echo ""
echo "=== fallback to HEAD only, and the CLI wiring ==="

REAL_NODE="$(command -v node)"
SHIM_DIR="$TMPBASE/shim"
NODE_LOG="$TMPBASE/node-merge-parents.log"
mkdir -p "$SHIM_DIR"
# shim_node <mode> — a `node` in SHIM_DIR: "fail" exits 3 for a merge-parents call, "log" records it.
shim_node() {
  local act='exit 3' q_log q_node
  q_log="$(printf '%q' "$NODE_LOG")"
  q_node="$(printf '%q' "$REAL_NODE")"
  [ "$1" = "log" ] && act='printf "%s\n" "$*" >> '"$q_log"
  printf '%s\n' '#!/usr/bin/env bash' \
    '[[ "$*" == *merge-parents* ]] && '"$act" \
    "exec $q_node \"\$@\"" > "$SHIM_DIR/node"
  chmod +x "$SHIM_DIR/node"
  : > "$NODE_LOG"
}
# expect_fallback <label> — HEAD-only verdict on the MERGE_HEAD-only si.sh, plus exactly one note.
expect_fallback() {
  expect_rc "$1: judged against HEAD only" 1 "$GATE_RC" "$GATE_ALL"
  expect_codes "$1: si.sh is new against HEAD" "$GATE_OUT" SELF_IMPLEMENTED_HARNESS 1
  assert_eq "$1: mp_note lines=$(count_note "$GATE_ALL")" "$1: mp_note lines=1"
}
SI_UP="tests/bin/si.sh=ex-si"

case_begin "octopus-merge-falls-back-with-a-note" "bin/lib/merge-parents.sh"
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

case_begin "corrupt-merge-head-falls-back-with-a-note" "bin/lib/merge-parents.sh"
R="$TMPBASE/fb-corrupt"
mergefx "$R" "" "$SI_UP" "" ""
printf '%s\n' 1234567890abcdef1234567890abcdef12345678 > "$R/.git/MERGE_HEAD"
gate "$R" "$FG"
expect_fallback "unreadable MERGE_HEAD"
case_end

case_begin "failing-merge-parents-cli-falls-back-with-a-note" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/fb-clifail"
mergefx "$R" "" "$SI_UP" "" ""
shim_node fail
GATE_PATH="$SHIM_DIR:$PATH"
gate "$R" "$FG" "$CM" "$LG"
GATE_PATH=""
expect_fallback "merge-parents CLI exits 3"
case_end

case_begin "criss-cross-judges-differing-parents-against-head-only" "bin/lib/merge-parents.sh"
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
assert_eq "malformed --merge-parents: mp_note lines=$(count_note "$CLI_OUT"$'\n'"$CLI_ERR")" \
  "malformed --merge-parents: mp_note lines=1"
case_end

case_begin "one-merge-parents-call-per-commit" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/fb-once"
mergefx "$R" "" "$SI_UP tests/bin/nomark.sh=ex-nomark" "" ""
shim_node log
GATE_PATH="$SHIM_DIR:$PATH"
gate "$R" "$FG" "$CM" "$LG"
GATE_PATH=""
n=0
while IFS= read -r _l; do [ -n "$_l" ] && n=$((n + 1)); done < "$NODE_LOG"
assert_eq "merge-parents CLI calls across three gates=$n" "merge-parents CLI calls across three gates=1"
case_end

case_begin "frontmatter-cli-receives-merge-parents" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/fb-wire"
XLOG="$TMPBASE/xtrace.log"
XDRIVER="$TMPBASE/gate-driver-x.sh"
printf '%s\n' 'exec 7>"$2"' 'BASH_XTRACEFD=7' '_cfg_dir="$1"' 'shift 2' 'set -x' \
  '. "$_cfg_dir/hooks/lib/precommit-tests-frontmatter.sh" || exit 98' '"$1"' > "$XDRIVER"
mergefx "$R" "" "$SI_UP" "" ""
( cd "$R" && bash "$RWT" 90 bash "$XDRIVER" "$SCRIPT_CHECKOUT_ROOT" "$XLOG" "$FG" ) >/dev/null 2>&1
wired=0
while IFS= read -r _l; do
  case "$_l" in *check-test-frontmatter.sh*--staged*--merge-parents*) wired=1 ;; esac
done < "$XLOG"
assert_eq "check-test-frontmatter.sh called with --merge-parents=$wired" \
  "check-test-frontmatter.sh called with --merge-parents=1"
case_end
