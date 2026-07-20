#!/usr/bin/env bash
# Tests: bin/check-test-frontmatter.sh, bin/lib/test-frontmatter-constants.sh
# Tags: TL2, scope:issue-specific, fix-1576-test-frontmatter
#
# TL2 test of bin/check-test-frontmatter.sh (renamed+extended from
# check-test-scope-tag.sh by #1576). Validates the `# Tests:` frontmatter
# header (presence + per-token FRONTMATTER_TOKEN_VALID_RE) plus the preserved
# `# Tags:` scope check, in both --staged (staged-blob read via git show) and
# --all (working-tree scan) modes.
#
# Fail-before-fix: the source script does not exist yet. Every TC below is
# EXPECTED TO FAIL until #1576 write-code lands check-test-frontmatter.sh.
#
# TL3 gap (what this test does NOT catch):
# - Real pre-commit hook firing via actual git commit attempt
# - gh API timeout behavior in a live GitHub environment
# Closest-to-action mitigation: gap checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="${CHECK_TEST_FRONTMATTER_BIN:-$REPO_ROOT/bin/check-test-frontmatter.sh}"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL+1)); echo "not ok - $1"; echo "    $2" >&2; }

if [[ ! -f "$SCRIPT" ]]; then
  fail "script exists" "script not found: $SCRIPT (implemented by #1576) — all cases fail-before-fix"
  echo "1..1"; echo "# PASS=$PASS FAIL=$FAIL"; exit 1
fi

# --- Helpers ---------------------------------------------------------------
# write_test_body <path> <tests-header-or-__NONE__> <tags-line-or-__NONE__>
# tests-header: the full "# Tests: ..." line, or __NONE__ to omit it.
# tags-line:    the full "# Tags: ..." line, or __NONE__ to omit it.
write_test_body() {
  local path="$1"; local tests="$2"; local tags="$3"
  mkdir -p "$(dirname "$path")"
  {
    echo '#!/usr/bin/env bash'
    [[ "$tests" != "__NONE__" ]] && echo "$tests"
    [[ "$tags"  != "__NONE__" ]] && echo "$tags"
    echo 'echo hi'
  } > "$path"
}

DEFAULT_TAGS='# Tags: TL2, scope:issue-specific'

# make_git_fixture -> echoes a fresh git repo root
make_git_fixture() {
  local root; root="$(mktemp -d)"
  git -C "$root" init -q
  git -C "$root" config user.email "t@example.com"
  git -C "$root" config user.name "t"
  mkdir -p "$root/tests" "$root/bin"
  # Provide a real path so valid tokens resolve where the script checks existence.
  echo '#!/usr/bin/env bash' > "$root/bin/foo.sh"
  echo '#!/usr/bin/env bash' > "$root/bin/bar.sh"
  echo "$root"
}

# run_staged <repo-root> <relpath> -> sets OUT ERR RC
# Stages <relpath> then runs the checker in --staged mode from inside the repo.
run_staged() {
  local root="$1"; local rel="$2"
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  git -C "$root" add -A >/dev/null 2>&1 || true
  set +e
  ( cd "$root" && bash "$SCRIPT" --staged "$rel" ) >"$outf" 2>"$errf"
  RC=$?
  set -e
  OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

# run_all <root> -> sets OUT ERR RC. Working-tree scan.
run_all() {
  local root="$1"
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  set +e
  ( cd "$root" && REPO_ROOT="$root" bash "$SCRIPT" --all "$root" ) >"$outf" 2>"$errf"
  RC=$?
  set -e
  OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

# --- Cases -----------------------------------------------------------------

# TC1: valid # Tests + valid scope tag => exit 0
R1="$(make_git_fixture)"
write_test_body "$R1/tests/tc1.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
run_staged "$R1" "tests/tc1.sh"
if [[ $RC -eq 0 ]]; then
  pass "TC1 valid Tests header + scope tag passes"
else
  fail "TC1 valid Tests header + scope tag passes" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R1"

# TC2: missing # Tests: header => exit 1 + MISSING_TESTS_HEADER
R2="$(make_git_fixture)"
write_test_body "$R2/tests/tc2.sh" '__NONE__' "$DEFAULT_TAGS"
run_staged "$R2" "tests/tc2.sh"
if [[ $RC -eq 1 && "$ERR" == *"MISSING_TESTS_HEADER"* ]]; then
  pass "TC2 missing Tests header fails with MISSING_TESTS_HEADER"
else
  fail "TC2 missing Tests header fails with MISSING_TESTS_HEADER" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R2"

# TC3: bracket annotation => exit 1 + INVALID_TESTS_TOKEN
R3="$(make_git_fixture)"
write_test_body "$R3/tests/tc3.sh" '# Tests: bin/foo.sh (some comment)' "$DEFAULT_TAGS"
run_staged "$R3" "tests/tc3.sh"
if [[ $RC -eq 1 && "$ERR" == *"INVALID_TESTS_TOKEN"* ]]; then
  pass "TC3 bracket annotation fails with INVALID_TESTS_TOKEN"
else
  fail "TC3 bracket annotation fails with INVALID_TESTS_TOKEN" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R3"

# TC4: space-separated (no comma) => exit 1 + INVALID_TESTS_TOKEN
R4="$(make_git_fixture)"
write_test_body "$R4/tests/tc4.sh" '# Tests: bin/foo.sh hooks/bar.js' "$DEFAULT_TAGS"
run_staged "$R4" "tests/tc4.sh"
if [[ $RC -eq 1 && "$ERR" == *"INVALID_TESTS_TOKEN"* ]]; then
  pass "TC4 space-separated tokens fail with INVALID_TESTS_TOKEN"
else
  fail "TC4 space-separated tokens fail with INVALID_TESTS_TOKEN" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R4"

# TC5: missing # Tags: (scope) with # Tests: present => exit 1 + MISSING_SCOPE_TAG
R5="$(make_git_fixture)"
write_test_body "$R5/tests/tc5.sh" '# Tests: bin/foo.sh' '__NONE__'
run_staged "$R5" "tests/tc5.sh"
if [[ $RC -eq 1 && "$ERR" == *"MISSING_SCOPE_TAG"* ]]; then
  pass "TC5 missing scope tag fails with MISSING_SCOPE_TAG"
else
  fail "TC5 missing scope tag fails with MISSING_SCOPE_TAG" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R5"

# TC6: # Tests: value empty => exit 1 + MISSING_TESTS_HEADER
R6="$(make_git_fixture)"
write_test_body "$R6/tests/tc6.sh" '# Tests:' "$DEFAULT_TAGS"
run_staged "$R6" "tests/tc6.sh"
if [[ $RC -eq 1 && "$ERR" == *"MISSING_TESTS_HEADER"* ]]; then
  pass "TC6 empty Tests value fails with MISSING_TESTS_HEADER"
else
  fail "TC6 empty Tests value fails with MISSING_TESTS_HEADER" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R6"

# TC7: multiple valid comma-separated tokens => exit 0
R7="$(make_git_fixture)"
write_test_body "$R7/tests/tc7.sh" '# Tests: bin/foo.sh, bin/bar.sh' "$DEFAULT_TAGS"
run_staged "$R7" "tests/tc7.sh"
if [[ $RC -eq 0 ]]; then
  pass "TC7 multiple valid tokens pass"
else
  fail "TC7 multiple valid tokens pass" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R7"

# TC8: --all over an all-OK fixture dir => exit 0
R8="$(make_git_fixture)"
write_test_body "$R8/tests/a.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
write_test_body "$R8/tests/b.sh" '# Tests: bin/bar.sh' '# Tags: TL2, scope:common'
run_all "$R8"
if [[ $RC -eq 0 ]]; then
  pass "TC8 --all passes when every file is well-formed"
else
  fail "TC8 --all passes when every file is well-formed" "rc=$RC out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R8"

# TC9: --all with one malformed file => exit 1
R9="$(make_git_fixture)"
write_test_body "$R9/tests/a.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
write_test_body "$R9/tests/b.sh" '# Tests: bin/foo.sh (bad annotation)' "$DEFAULT_TAGS"
run_all "$R9"
if [[ $RC -eq 1 ]]; then
  pass "TC9 --all fails when one file is malformed"
else
  fail "TC9 --all fails when one file is malformed" "rc=$RC out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R9"

# TC10: tests/_archive/ files are skipped (malformed archive file => still exit 0)
R10="$(make_git_fixture)"
write_test_body "$R10/tests/a.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
write_test_body "$R10/tests/_archive/old.sh" '# Tests: bin/foo.sh (bad)' '__NONE__'
run_all "$R10"
if [[ $RC -eq 0 ]]; then
  pass "TC10 tests/_archive files are skipped"
else
  fail "TC10 tests/_archive files are skipped" "rc=$RC out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R10"

# TC11: staged blob is read (staged malformed, working-tree clean) => exit 1
R11="$(make_git_fixture)"
# Stage a malformed version.
write_test_body "$R11/tests/tc11.sh" '# Tests: bin/foo.sh (staged bad)' "$DEFAULT_TAGS"
git -C "$R11" add -A >/dev/null 2>&1
# Overwrite working tree with a clean version WITHOUT staging it.
write_test_body "$R11/tests/tc11.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
outf="$(mktemp)"; errf="$(mktemp)"
set +e
( cd "$R11" && bash "$SCRIPT" --staged "tests/tc11.sh" ) >"$outf" 2>"$errf"
RC=$?
set -e
OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
rm -f "$outf" "$errf"
if [[ $RC -eq 1 && "$ERR" == *"INVALID_TESTS_TOKEN"* ]]; then
  pass "TC11 --staged reads staged blob (malformed) not clean working tree"
else
  fail "TC11 --staged reads staged blob (malformed) not clean working tree" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R11"

# --- Summary ---------------------------------------------------------------
echo "1..$((PASS+FAIL))"
echo "# PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
