#!/usr/bin/env bash
# Tests: tests/lib/fixture-template.sh
# Tags: fixture, template, scope:issue-specific
# Cases T1a-T1h of #2723: the template helper clones a repo with the right state and isolation.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=../lib/fixture-template.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/fixture-template.sh"

_TMP_ROOT="$(make_tmp)"; readonly _TMP_ROOT
trap 'rm -rf "$_TMP_ROOT"' EXIT
harness_isolate "$_TMP_ROOT/iso"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

TPL="$_TMP_ROOT/tpl"
TPL_NC="$_TMP_ROOT/tpl-nc"
fixture_template_git_repo "$TPL" main || { echo "FAIL: template build"; exit 1; }
fixture_template_git_repo "$TPL_NC" trunk --no-commit || { echo "FAIL: unborn template build"; exit 1; }

case_begin "clone-has-hookspath-and-initial-commit" "tests/lib/fixture-template.sh"
A1="$_TMP_ROOT/a1"
fixture_template_copy "$TPL" "$A1"
HP="$(git -C "$A1" config core.hooksPath)"
case "$HP" in
  /dev/null|nul) pass "core.hooksPath disables hooks ($HP)" ;;
  *) fail "core.hooksPath disables hooks" "got=$HP" ;;
esac
assert_eq "$(git -C "$A1" rev-parse HEAD)" "$(git -C "$TPL" rev-parse HEAD)"
assert_eq "$(git -C "$A1" rev-parse --abbrev-ref HEAD)" "main"
case_end

case_begin "clone-commit-leaves-template-head" "tests/lib/fixture-template.sh"
H0="$(git -C "$TPL" rev-parse HEAD)"
printf 'x\n' >"$A1/b.txt"
git -C "$A1" add b.txt
git -C "$A1" commit -q -m "clone commit"
assert_eq "$(git -C "$TPL" rev-parse HEAD)" "$H0"
case_end

case_begin "clone-supports-worktree-add" "tests/lib/fixture-template.sh"
if git -C "$A1" worktree add -q -b wt-branch "$_TMP_ROOT/a1-wt" >/dev/null 2>&1; then
  pass "worktree add succeeds in a clone"
else
  fail "worktree add succeeds in a clone"
fi
case_end

case_begin "clone-refuses-existing-destination" "tests/lib/fixture-template.sh"
mkdir -p "$_TMP_ROOT/exists"
if fixture_template_copy "$TPL" "$_TMP_ROOT/exists" >/dev/null 2>&1; then
  fail "existing destination is refused"
else
  pass "existing destination is refused"
fi
case_end

case_begin "clones-are-independent" "tests/lib/fixture-template.sh"
fixture_template_copy "$TPL" "$_TMP_ROOT/c1"
fixture_template_copy "$TPL" "$_TMP_ROOT/c2"
printf 'only-c1\n' >"$_TMP_ROOT/c1/only-c1.txt"
if [[ -e "$_TMP_ROOT/c2/only-c1.txt" ]]; then
  fail "file added to one clone is absent from the other"
else
  pass "file added to one clone is absent from the other"
fi
case_end

case_begin "committed-template-clone-is-clean" "tests/lib/fixture-template.sh"
assert_eq "$(git -C "$_TMP_ROOT/c2" status --porcelain)" ""
if [[ -f "$_TMP_ROOT/c2/README.md" ]]; then
  pass "README present in the working tree"
else
  fail "README present in the working tree"
fi
case_end

case_begin "unborn-template-clone-has-no-head" "tests/lib/fixture-template.sh"
U1="$_TMP_ROOT/u1"
fixture_template_copy "$TPL_NC" "$U1"
if git -C "$U1" rev-parse --verify HEAD >/dev/null 2>&1; then
  fail "unborn clone has no HEAD"
else
  pass "unborn clone has no HEAD"
fi
assert_eq "$(git -C "$U1" status --porcelain)" ""
assert_eq "$(find "$U1" -mindepth 1 -maxdepth 1 -not -name .git | wc -l | tr -d ' ')" "0"
case_end

case_begin "template-change-propagates-and-clones-stay-isolated" "tests/lib/fixture-template.sh"
PT="$_TMP_ROOT/probe-tpl"
fixture_template_git_repo "$PT" main
git -C "$PT" config test.template-probe known
printf 'probe\n' >"$PT/probe.txt"
PA="$_TMP_ROOT/probe-a"
fixture_template_copy "$PT" "$PA"
assert_eq "$(git -C "$PA" config test.template-probe)" "known"
if [[ -f "$PA/probe.txt" ]]; then
  pass "clone A receives the template file"
else
  fail "clone A receives the template file"
fi
git -C "$PA" config test.clone-only a-only
printf 'a\n' >"$PA/a-only.txt"
PB="$_TMP_ROOT/probe-b"
fixture_template_copy "$PT" "$PB"
assert_eq "$(git -C "$PB" config test.template-probe)" "known"
assert_eq "$(git -C "$PB" config test.clone-only || true)" ""
if [[ -e "$PB/a-only.txt" ]]; then
  fail "clone B does not receive A's file"
else
  pass "clone B does not receive A's file"
fi
assert_eq "$(git -C "$PT" config test.clone-only || true)" ""
if [[ -e "$PT/a-only.txt" ]]; then
  fail "template is not dirtied by clone A"
else
  pass "template is not dirtied by clone A"
fi
case_end

case_begin "copy-refuses-missing-template" "tests/lib/fixture-template.sh"
if fixture_template_copy "$_TMP_ROOT/no-such-template" "$_TMP_ROOT/m1" >/dev/null 2>&1; then
  fail "missing template is refused"
else
  pass "missing template is refused"
fi
if [[ -e "$_TMP_ROOT/m1" ]]; then
  fail "no destination is created for a missing template"
else
  pass "no destination is created for a missing template"
fi
case_end

case_begin "empty-arguments-are-refused" "tests/lib/fixture-template.sh"
if fixture_template_copy "" "$_TMP_ROOT/e1" >/dev/null 2>&1; then
  fail "empty template argument is refused"
else
  pass "empty template argument is refused"
fi
if fixture_template_copy "$TPL" "" >/dev/null 2>&1; then
  fail "empty destination argument is refused"
else
  pass "empty destination argument is refused"
fi
if fixture_template_copy >/dev/null 2>&1; then
  fail "no arguments are refused"
else
  pass "no arguments are refused"
fi
if fixture_template_git_repo "" >/dev/null 2>&1; then
  fail "git_repo with an empty destination is refused"
else
  pass "git_repo with an empty destination is refused"
fi
case_end

case_begin "paths-with-spaces-work" "tests/lib/fixture-template.sh"
SP_TPL="$_TMP_ROOT/tpl with space"
SP_DST="$_TMP_ROOT/dest with space"
fixture_template_git_repo "$SP_TPL" main
fixture_template_copy "$SP_TPL" "$SP_DST"
assert_eq "$(git -C "$SP_DST" rev-parse HEAD)" "$(git -C "$SP_TPL" rev-parse HEAD)"
assert_eq "$(git -C "$SP_DST" status --porcelain)" ""
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
