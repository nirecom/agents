#!/usr/bin/env bash
# tests/bin/feature-2502-retire-issue-stem.sh
# Tests: bin/lib/test-language-registry.sh, bin/lib/test-retire-predicate.sh, bin/audit-tests.sh, bin/audit-tests-common.sh
# Tags: TL2, bin, audit-tests, retire, test-language-registry, pytest, scope:issue-specific
# Issue #2502 S5-4c: the issue number is read from the name with the entry's issueNamePrefix
# dropped (tlr_issue_stem), so test_feature-<N>-*.py is issue-specific like feature-<N>-*.sh.
# Only the pytest entry has a prefix; bash, pester and js names keep their results. The
# fixture repo checks that audit-tests.sh selects such a pytest file and audit-tests-common.sh
# leaves it alone.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
export HOME="$TMPBASE/home"
mkdir -p "$HOME"
export NO_LOG=true
harness_isolate "$TMPBASE/state"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE CASE_EMBED_CACHE_DIR

# fx_checkout / has_line: the registry suite's helpers (one owner).
# shellcheck source=test-language-registry/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/test-language-registry/_lib.sh"

# row <name> — "<issue-stem>|<scope>|<ref>|<number>" for <name>, in a fresh shell.
row() {
  run_with_timeout 60 bash -c '. "$1/bin/lib/test-language-registry.sh" || exit 97
. "$1/bin/lib/test-retire-predicate.sh" || exit 97
tlr_load || exit 96
printf "%s|%s|%s|%s\n" "$(tlr_issue_stem "$2")" "$(trp_scope_of "$2")" "$(trp_issue_ref "$2")" "$(trp_issue_number "$2")"' _ "$SCRIPT_CHECKOUT_ROOT" "$1" 2>"$TMPBASE/row.err"
}

case_begin "issue-stem-pytest-names" "bin/lib/test-language-registry.sh"
while IFS='|' read -r name want; do
  [ -n "$name" ] || continue
  assert_eq "$name: $(row "$name")" "$name: $want"
done <<'ROWS'
test_feature-2502-x.py|feature-2502-x|issue-specific|explicit|2502
test_fix-12-y.py|fix-12-y|common|explicit|12
test_foo.py|foo|common|none|
ROWS
case_end

case_begin "issue-stem-other-languages-unchanged" "bin/lib/test-retire-predicate.sh"
# The bash / pester / js entries have an empty prefix: their results stay as they are today,
# a bash name that starts with test_ included; a name no entry covers stays as it is.
while IFS='|' read -r name want; do
  [ -n "$name" ] || continue
  assert_eq "$name: $(row "$name")" "$name: $want"
done <<'ROWS'
feature-2502-x.sh|feature-2502-x|issue-specific|explicit|2502
feature-2502-x.Tests.ps1|feature-2502-x|issue-specific|explicit|2502
feature-2502-x.js|feature-2502-x|issue-specific|explicit|2502
test_feature-2502-x.sh|test_feature-2502-x|common|ambiguous|
README.md|README.md|common|none|
ROWS
case_end

# The fixture repo: an orphan pytest file named after issue #9999 (every header target gone).
CO="$TMPBASE/co"
fx_checkout "$CO"
for _f in audit-tests.sh audit-tests-common.sh; do cp "$SCRIPT_CHECKOUT_ROOT/bin/$_f" "$CO/bin/$_f"; done
PY_REL=tests/bin/test_feature-9999-x.py
FR="$TMPBASE/fr"
harness_git_init "$FR"
git -C "$FR" config user.email t@example.com
git -C "$FR" config user.name t
mkdir -p "$FR/tests/bin"
printf '%s\n' '# ''Tests: bin/gone.sh' '# ''Tags: TL2, scope:issue-specific' '' '' \
  'def test_one():' '    assert True' >"$FR/$PY_REL"
git -C "$FR" add -A >/dev/null 2>&1
git -C "$FR" commit -q -m fixture >/dev/null 2>&1

# audit <script> <args...> — the checkout's audit script from the fixture repo; sets AU_OUT.
audit() {
  local script="$1"
  shift
  (
    cd "$FR" || exit 98
    run_with_timeout 180 bash "$CO/bin/$script" "$@"
  ) >"$TMPBASE/au.out" 2>"$TMPBASE/au.err" || true
  AU_OUT="$(cat "$TMPBASE/au.out")"
}

case_begin "audit-tests-selects-the-pytest-issue-file" "bin/audit-tests.sh"
if command -v uv >/dev/null 2>&1; then
  audit audit-tests.sh --dry-run --offline --format text
  has_line "audit-tests.sh: candidate line" "$AU_OUT" "CANDIDATE: $PY_REL"
  case "$AU_OUT" in
    *"  Issue: #9999 ("*) pass "audit-tests.sh: Issue: #9999" ;;
    *) fail "audit-tests.sh: Issue: #9999" "out=[$AU_OUT] err=[$(cat "$TMPBASE/au.err")]" ;;
  esac
else
  skip "audit-tests.sh selection: uv not available (the reader would hold the file)"
fi
case_end

case_begin "audit-tests-common-skips-the-pytest-issue-file" "bin/audit-tests-common.sh"
audit audit-tests-common.sh --dry-run --offline --format text
case "$AU_OUT" in
  "# audit-tests-common.sh report"*) pass "audit-tests-common.sh: report produced" ;;
  *) fail "audit-tests-common.sh: report produced" "out=[$AU_OUT] err=[$(cat "$TMPBASE/au.err")]" ;;
esac
case "$AU_OUT" in
  *"test_feature-9999-x.py"*) fail "audit-tests-common.sh: the issue file is out of scope" "out=[$AU_OUT]" ;;
  *) pass "audit-tests-common.sh: the issue file is out of scope" ;;
esac
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
