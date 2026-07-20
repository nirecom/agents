#!/usr/bin/env bash
# Tests: bin/check-test-frontmatter.sh
# Tags: TL2, audit-tests, retire, scope:issue-specific
#
# TL2 test of bin/check-test-frontmatter.sh, which enforces that every test
# file under tests/ carries a `# Tags: scope:...` tag. Covers --staged
# (explicit file list) and --all (repo-wide fixture scan) modes. Source
# under test is being created by #1557 — cases go green once the script
# lands.
#
# TL3 gap (what this test does NOT catch):
# - Real `git diff --cached` staged-file discovery in --staged mode
#   (this test passes the file list explicitly to stay hermetic)
# Closest-to-action mitigation: pre-commit hook exercises the real staged
# path before commit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="${CHECK_TEST_FRONTMATTER_BIN:-$REPO_ROOT/bin/check-test-frontmatter.sh}"
FIXTURE_ROOT="$SCRIPT_DIR/fix-1557-check-test-scope-tag/fixture"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL+1)); echo "not ok - $1"; echo "    $2" >&2; }

if [[ ! -f "$SCRIPT" ]]; then
  fail "script exists" "script not found: $SCRIPT (implemented by #1557)"
  echo "1..1"; echo "# PASS=$PASS FAIL=$FAIL"; exit 1
fi

# --- Helpers ---------------------------------------------------------------
# run <args...> -> sets OUT ERR RC. --staged cases pass explicit file paths.
run_check() {
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  set +e
  bash "$SCRIPT" "$@" >"$outf" 2>"$errf"
  RC=$?
  set -e
  OUT="$(cat "$outf")"
  ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

# run_check_all <fixture-root> -> sets OUT ERR RC.
# --all mode scans a repo's tests/ tree. Support both plausible designs:
#   (a) script accepts the root as a positional arg after --all, and
#   (b) script resolves the root from CWD / REPO_ROOT env.
run_check_all() {
  local root="$1"
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  set +e
  ( cd "$root" && REPO_ROOT="$root" bash "$SCRIPT" --all "$root" ) >"$outf" 2>"$errf"
  RC=$?
  set -e
  OUT="$(cat "$outf")"
  ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

# write_test <path> <tags-line-or-empty>
write_test() {
  local path="$1"; local tags="$2"
  mkdir -p "$(dirname "$path")"
  {
    echo '#!/usr/bin/env bash'
    echo '# Tests: bin/whatever.sh'
    [[ -n "$tags" ]] && echo "$tags"
    echo 'echo hi'
  } > "$path"
}

# --- Staged fixtures -------------------------------------------------------
STAGE_DIR="$(mktemp -d)"
GOOD="$STAGE_DIR/tests/good.sh"
BAD="$STAGE_DIR/tests/bad.sh"
NONTEST="$STAGE_DIR/src/thing.sh"
ARCHIVE="$STAGE_DIR/tests/_archive/old.sh"
SPACED="$STAGE_DIR/tests/spaced.sh"
write_test "$GOOD"    "# Tags: TL2, scope:issue-specific"
write_test "$BAD"     "# Tags: TL2, workflow"
write_test "$NONTEST" "# Tags: whatever"
write_test "$ARCHIVE" "# Tags: TL2, no-scope-here"
write_test "$SPACED"  "# Tags: scope: common"

# --- Cases -----------------------------------------------------------------

# TC1: --staged file with a scope tag => exit 0
run_check --staged "$GOOD"
if [[ $RC -eq 0 ]]; then
  pass "TC1 staged file with scope tag passes"
else
  fail "TC1 staged file with scope tag passes" "rc=$RC err=<<$ERR>>"
fi

# TC2: --staged file without a scope tag => exit 1 + MISSING_SCOPE_TAG on stderr
run_check --staged "$BAD"
if [[ $RC -eq 1 && "$ERR" == *"MISSING_SCOPE_TAG"* ]]; then
  pass "TC2 staged file without scope tag fails with MISSING_SCOPE_TAG"
else
  fail "TC2 staged file without scope tag fails with MISSING_SCOPE_TAG" "rc=$RC err=<<$ERR>>"
fi

# TC3: --staged non-tests/ file => ignored, exit 0
run_check --staged "$NONTEST"
if [[ $RC -eq 0 ]]; then
  pass "TC3 non-tests file is ignored"
else
  fail "TC3 non-tests file is ignored" "rc=$RC err=<<$ERR>>"
fi

# TC4: --staged tests/_archive/ file => ignored, exit 0
run_check --staged "$ARCHIVE"
if [[ $RC -eq 0 ]]; then
  pass "TC4 tests/_archive file is ignored"
else
  fail "TC4 tests/_archive file is ignored" "rc=$RC err=<<$ERR>>"
fi

# TC7: `# Tags: scope: common` (space after colon) => accepted, exit 0
run_check --staged "$SPACED"
if [[ $RC -eq 0 ]]; then
  pass "TC7 scope tag with space after colon is accepted"
else
  fail "TC7 scope tag with space after colon is accepted" "rc=$RC err=<<$ERR>>"
fi

rm -rf "$STAGE_DIR"

# --- --all mode fixtures ---------------------------------------------------
# TC5: --all over the committed all-good fixture => exit 0
run_check_all "$FIXTURE_ROOT"
rc_all_ok=$RC
if [[ $rc_all_ok -eq 0 ]]; then
  pass "TC5 --all passes when every test file is tagged"
else
  fail "TC5 --all passes when every test file is tagged" "rc=$rc_all_ok out=<<$OUT>> err=<<$ERR>>"
fi

# TC6: --all over a fixture with one untagged file => exit 1
ALL_BAD="$(mktemp -d)"
mkdir -p "$ALL_BAD/tests"
write_test "$ALL_BAD/tests/a.sh" "# Tags: TL2, scope:common"
write_test "$ALL_BAD/tests/b.sh" "# Tags: TL2, no-scope"
run_check_all "$ALL_BAD"
rc_all_bad=$RC
if [[ $rc_all_bad -eq 1 ]]; then
  pass "TC6 --all fails when a test file lacks a scope tag"
else
  fail "TC6 --all fails when a test file lacks a scope tag" "rc=$rc_all_bad out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$ALL_BAD"

# TC8: no arguments => usage error, exit 2
run_check
if [[ $RC -eq 2 ]]; then
  pass "TC8 no arguments exits 2"
else
  fail "TC8 no arguments exits 2" "rc=$RC err=<<$ERR>>"
fi

# TC9: scope:issue-specific accepted in --staged mode (CPR-5 symmetric coverage)
# TC1 uses scope:issue-specific implicitly; TC9 asserts it explicitly with an
# isolated fixture so both scope variants (common, issue-specific) have named cases.
STAGE9_DIR="$(mktemp -d)"
ISSUE_SPECIFIC="$STAGE9_DIR/tests/issue-specific.sh"
write_test "$ISSUE_SPECIFIC" "# Tags: TL2, scope:issue-specific"
run_check --staged "$ISSUE_SPECIFIC"
if [[ $RC -eq 0 ]]; then
  pass "TC9 scope:issue-specific accepted in staged mode"
else
  fail "TC9 scope:issue-specific accepted in staged mode" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$STAGE9_DIR"

# --- Summary ---------------------------------------------------------------
echo "1..$((PASS+FAIL))"
echo "# PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
