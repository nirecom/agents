#!/usr/bin/env bash
# Tests: bin/check-test-frontmatter.sh, bin/lib/test-frontmatter-constants.sh
# Tags: TL2, scope:issue-specific, fix-1576-test-frontmatter
# TL2 test of bin/check-test-frontmatter.sh: validates the `# Tests:` header
# (presence + per-token FRONTMATTER_TOKEN_VALID_RE) and the `# Tags:` scope tag
# in --staged (staged-blob via git show) and --all (working-tree scan) modes.
# TL3 gap: real pre-commit hook firing and live gh API timeouts are not covered;
# gap checked at WORKFLOW_USER_VERIFIED preflight (check-verification-gate.sh,
# category hook-registration).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
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
  git -C "$root" config core.hooksPath /dev/null 2>/dev/null || true
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

case_begin() { echo "--- group: $1 ---"; }
case_end()   { :; }

case_begin "staged-mode" "bin/check-test-frontmatter.sh"

# TC1: valid # Tests + valid scope tag => exit 0
# 2-level paths (tests/bin/) are used throughout staged-mode: a flat tests/<name>.sh
# is now rejected outright (#1834, group 3), which would mask the check_content
# behavior these cases target.
R1="$(make_git_fixture)"
write_test_body "$R1/tests/bin/tc1.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
run_staged "$R1" "tests/bin/tc1.sh"
if [[ $RC -eq 0 ]]; then
  pass "TC1 valid Tests header + scope tag passes"
else
  fail "TC1 valid Tests header + scope tag passes" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R1"

# TC2: missing # Tests: header => exit 1 + MISSING_TESTS_HEADER
R2="$(make_git_fixture)"
write_test_body "$R2/tests/bin/tc2.sh" '__NONE__' "$DEFAULT_TAGS"
run_staged "$R2" "tests/bin/tc2.sh"
if [[ $RC -eq 1 && "$ERR" == *"MISSING_TESTS_HEADER"* ]]; then
  pass "TC2 missing Tests header fails with MISSING_TESTS_HEADER"
else
  fail "TC2 missing Tests header fails with MISSING_TESTS_HEADER" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R2"

# TC3: bracket annotation => exit 1 + INVALID_TESTS_TOKEN
R3="$(make_git_fixture)"
write_test_body "$R3/tests/bin/tc3.sh" '# Tests: bin/foo.sh (some comment)' "$DEFAULT_TAGS"
run_staged "$R3" "tests/bin/tc3.sh"
if [[ $RC -eq 1 && "$ERR" == *"INVALID_TESTS_TOKEN"* ]]; then
  pass "TC3 bracket annotation fails with INVALID_TESTS_TOKEN"
else
  fail "TC3 bracket annotation fails with INVALID_TESTS_TOKEN" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R3"

# TC4: space-separated (no comma) => exit 1 + INVALID_TESTS_TOKEN
R4="$(make_git_fixture)"
write_test_body "$R4/tests/bin/tc4.sh" '# Tests: bin/foo.sh hooks/bar.js' "$DEFAULT_TAGS"
run_staged "$R4" "tests/bin/tc4.sh"
if [[ $RC -eq 1 && "$ERR" == *"INVALID_TESTS_TOKEN"* ]]; then
  pass "TC4 space-separated tokens fail with INVALID_TESTS_TOKEN"
else
  fail "TC4 space-separated tokens fail with INVALID_TESTS_TOKEN" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R4"

# TC5: missing # Tags: (scope) with # Tests: present => exit 1 + MISSING_SCOPE_TAG
R5="$(make_git_fixture)"
write_test_body "$R5/tests/bin/tc5.sh" '# Tests: bin/foo.sh' '__NONE__'
run_staged "$R5" "tests/bin/tc5.sh"
if [[ $RC -eq 1 && "$ERR" == *"MISSING_SCOPE_TAG"* ]]; then
  pass "TC5 missing scope tag fails with MISSING_SCOPE_TAG"
else
  fail "TC5 missing scope tag fails with MISSING_SCOPE_TAG" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R5"

# TC6: # Tests: value empty => exit 1 + MISSING_TESTS_HEADER
R6="$(make_git_fixture)"
write_test_body "$R6/tests/bin/tc6.sh" '# Tests:' "$DEFAULT_TAGS"
run_staged "$R6" "tests/bin/tc6.sh"
if [[ $RC -eq 1 && "$ERR" == *"MISSING_TESTS_HEADER"* ]]; then
  pass "TC6 empty Tests value fails with MISSING_TESTS_HEADER"
else
  fail "TC6 empty Tests value fails with MISSING_TESTS_HEADER" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R6"

# TC7: multiple valid comma-separated tokens => exit 0
R7="$(make_git_fixture)"
write_test_body "$R7/tests/bin/tc7.sh" '# Tests: bin/foo.sh, bin/bar.sh' "$DEFAULT_TAGS"
run_staged "$R7" "tests/bin/tc7.sh"
if [[ $RC -eq 0 ]]; then
  pass "TC7 multiple valid tokens pass"
else
  fail "TC7 multiple valid tokens pass" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R7"

# TC8: --all over an all-OK fixture dir => exit 0
R8="$(make_git_fixture)"
write_test_body "$R8/tests/bin/a.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
write_test_body "$R8/tests/bin/b.sh" '# Tests: bin/bar.sh' '# Tags: TL2, scope:common'
run_all "$R8"
if [[ $RC -eq 0 ]]; then
  pass "TC8 --all passes when every file is well-formed"
else
  fail "TC8 --all passes when every file is well-formed" "rc=$RC out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R8"

# TC9: --all with one malformed file => exit 1
R9="$(make_git_fixture)"
write_test_body "$R9/tests/bin/a.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
write_test_body "$R9/tests/bin/b.sh" '# Tests: bin/foo.sh (bad annotation)' "$DEFAULT_TAGS"
run_all "$R9"
if [[ $RC -eq 1 ]]; then
  pass "TC9 --all fails when one file is malformed"
else
  fail "TC9 --all fails when one file is malformed" "rc=$RC out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R9"

# TC10: tests/_archive/ files are skipped (malformed archive file => still exit 0)
R10="$(make_git_fixture)"
write_test_body "$R10/tests/bin/a.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
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
write_test_body "$R11/tests/bin/tc11.sh" '# Tests: bin/foo.sh (staged bad)' "$DEFAULT_TAGS"
git -C "$R11" add -A >/dev/null 2>&1
# Overwrite working tree with a clean version WITHOUT staging it.
write_test_body "$R11/tests/bin/tc11.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
outf="$(mktemp)"; errf="$(mktemp)"
set +e
( cd "$R11" && bash "$SCRIPT" --staged "tests/bin/tc11.sh" ) >"$outf" 2>"$errf"
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
case_end

case_begin "two-level-layout" "bin/lib/test-frontmatter-constants.sh"
# --- #1834 Group 2: 2-level tests/ layout (category subdirs) ---------------
# --staged already matches subdir paths (2a-2c pass now); --all must be taught
# to scan subdirs (2d, gated on the C4 fix); tests/_archive/ stays skipped in
# --staged (2e, passes now).

# 2a: --staged over a VALID tests/hooks/ file => exit 0, no error token
R="$(make_git_fixture)"
write_test_body "$R/tests/hooks/valid.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
run_staged "$R" "tests/hooks/valid.sh"
if [[ $RC -eq 0 && -z "$ERR" ]]; then
  pass "2a --staged validates a valid tests/hooks/ file (exit 0)"
else
  fail "2a --staged validates a valid tests/hooks/ file" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R"

# 2b: --staged tests/hooks/ file missing # Tests: => MISSING_TESTS_HEADER
R="$(make_git_fixture)"
write_test_body "$R/tests/hooks/no-tests.sh" '__NONE__' "$DEFAULT_TAGS"
run_staged "$R" "tests/hooks/no-tests.sh"
if [[ $RC -eq 1 && "$ERR" == *"MISSING_TESTS_HEADER"* ]]; then
  pass "2b --staged tests/hooks/ missing Tests header => MISSING_TESTS_HEADER"
else
  fail "2b --staged tests/hooks/ missing Tests header" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R"

# 2c: --staged tests/hooks/ file missing # Tags: => MISSING_SCOPE_TAG
R="$(make_git_fixture)"
write_test_body "$R/tests/hooks/no-tags.sh" '# Tests: bin/foo.sh' '__NONE__'
run_staged "$R" "tests/hooks/no-tags.sh"
if [[ $RC -eq 1 && "$ERR" == *"MISSING_SCOPE_TAG"* ]]; then
  pass "2c --staged tests/hooks/ missing scope tag => MISSING_SCOPE_TAG"
else
  fail "2c --staged tests/hooks/ missing scope tag" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R"

# 2d: --all must scan tests/hooks/ subdirs (C4 fix). A malformed subdir file
# fails --all post-fix (rc 1 + INVALID_TESTS_TOKEN); pre-fix the subdir is
# silently unscanned (rc 0). The outer skip guard at the top already confirmed
# tests/hooks/ exists in the real repo, so rc=0 here is a test failure, not a
# skip — the fix must be applied.
R="$(make_git_fixture)"
write_test_body "$R/tests/hooks/malformed.sh" '# Tests: bin/foo.sh (bad annotation)' "$DEFAULT_TAGS"
run_all "$R"
if [[ $RC -eq 0 ]]; then
  fail "2d --all scans tests/hooks/ (C4 fix not applied — rc=0 means subdir silently unscanned)"
elif [[ $RC -eq 1 && "$ERR" == *"INVALID_TESTS_TOKEN"* && "$ERR" == *"tests/hooks/malformed.sh"* ]]; then
  pass "2d --all scans tests/hooks/ subdir and flags a malformed file (C4 fix applied)"
else
  fail "2d --all scans tests/hooks/ subdir" "unexpected rc=$RC out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R"

# 2e: --staged tests/_archive/ file is skipped even when malformed => exit 0
R="$(make_git_fixture)"
write_test_body "$R/tests/_archive/old.sh" '# Tests: bin/foo.sh (bad)' '__NONE__'
run_staged "$R" "tests/_archive/old.sh"
if [[ $RC -eq 0 && -z "$ERR" ]]; then
  pass "2e --staged tests/_archive/ file is skipped (exit 0)"
else
  fail "2e --staged tests/_archive/ file is skipped" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R"

# 2f: --all scans ALL six category subdirs, not just tests/hooks/. The 2d gate
# ensures the C4 fix is applied before this case runs.
CATS_R="$(make_git_fixture)"
for cat in hooks bin skills agents install tests; do
  write_test_body "$CATS_R/tests/$cat/malformed-$cat.sh" '# Tests: bin/foo.sh (bad annotation)' "$DEFAULT_TAGS"
done
run_all "$CATS_R"
missing_cats=""
for cat in hooks bin skills agents install tests; do
  if [[ "$ERR" == *"malformed-$cat.sh"* || "$OUT" == *"malformed-$cat.sh"* ]]; then
    :
  else
    missing_cats="$missing_cats $cat"
  fi
done
if [[ $RC -ne 0 && -z "$missing_cats" ]]; then
  pass "2f --all scans all six category subdirs (hooks/bin/skills/agents/install/tests)"
elif [[ -n "$missing_cats" ]]; then
  fail "2f --all scans all six category subdirs" "missing:$missing_cats err=<<$ERR>>"
else
  fail "2f --all with malformed files in all six categories" "unexpected rc=$RC err=<<$ERR>>"
fi
rm -rf "$CATS_R"

# 2g: --all must NOT scan 3-level split sub-files (tests/hooks/dispatcher/part.sh).
# The fix uses a `tests/<cat>/*.sh` glob; `*.sh` does not cross `/`, so 3-level
# paths are naturally excluded. This case documents that invariant explicitly.
SPLIT_R="$(make_git_fixture)"
write_test_body "$SPLIT_R/tests/hooks/dispatcher.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
write_test_body "$SPLIT_R/tests/hooks/dispatcher/part.sh" '# Tests: bin/foo.sh (bad annotation)' "$DEFAULT_TAGS"
run_all "$SPLIT_R"
if [[ $RC -eq 0 ]]; then
  pass "2g --all excludes 3-level split sub-files (tests/hooks/dispatcher/part.sh not scanned)"
else
  fail "2g --all excludes 3-level split sub-files" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$SPLIT_R"
case_end

case_begin "harness-source-check" "bin/check-test-frontmatter.sh"
# --- #1834 C6: harness-source check for staged NESTED (2-level) test files ----
# Pre-fix, the harness-source check only fires for top-level tests/*.sh (the
# base=*/* guard excludes tests/<category>/*.sh). Post-fix it must also fire for
# newly-added 2-level paths. The check only runs when the repo ships
# tests/lib/harness.sh, so each fixture below creates one.

# 6a: NEW staged tests/hooks/bad-test.sh WITHOUT sourcing harness.sh
#     => MISSING_HARNESS_SOURCE (post-fix). The outer skip guard confirmed
#     tests/hooks/ exists, so a missing check is a failure, not a skip.
R="$(make_git_fixture)"
mkdir -p "$R/tests/lib"
echo '# harness stub' > "$R/tests/lib/harness.sh"
write_test_body "$R/tests/hooks/bad-test.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
run_staged "$R" "tests/hooks/bad-test.sh"
if [[ "$ERR" != *"MISSING_HARNESS_SOURCE"* ]]; then
  fail "6a nested-path harness-source check (C6 fix not applied — MISSING_HARNESS_SOURCE not emitted for tests/hooks/)"
elif [[ $RC -eq 1 && "$ERR" == *"MISSING_HARNESS_SOURCE"* ]]; then
  pass "6a --staged new tests/hooks/ file without harness source => MISSING_HARNESS_SOURCE"
else
  fail "6a --staged new tests/hooks/ file without harness source" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R"

# 6b: NEW staged tests/hooks/good-test.sh WITH harness source => no
#     MISSING_HARNESS_SOURCE and exit 0 (positive case).
R="$(make_git_fixture)"
mkdir -p "$R/tests/lib" "$R/tests/hooks"
echo '# harness stub' > "$R/tests/lib/harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo '# Tests: bin/foo.sh'
  echo "$DEFAULT_TAGS"
  echo 'AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"'
  echo 'source "$AGENTS_DIR/tests/lib/harness.sh"'
  echo 'echo hi'
} > "$R/tests/hooks/good-test.sh"
run_staged "$R" "tests/hooks/good-test.sh"
if [[ $RC -eq 0 && "$ERR" != *"MISSING_HARNESS_SOURCE"* ]]; then
  pass "6b --staged new tests/hooks/ file with harness source passes (no MISSING_HARNESS_SOURCE)"
else
  fail "6b --staged new tests/hooks/ file with harness source" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R"
case_end

case_begin "flat-sh-rejection" "bin/check-test-frontmatter.sh"
# --- #1834 Group 3: reject NEWLY-ADDED flat tests/<name>.sh --------------------
# A .sh test entrypoint must live under tests/<category>/. A new flat tests/<name>.sh
# is rejected (FLAT_TEST_SH_REJECTED) even with valid frontmatter; an existing flat
# file (present in HEAD) is grandfathered (#2372 sweeps it later); tests/run-all.sh
# is the infra runner and is exempt from flat-rejection; a 2-level path is accepted.

# 3a: NEW flat tests/newflat.sh with VALID frontmatter => FLAT_TEST_SH_REJECTED, exit 1.
# Validity does not save it — placement is the violation.
R="$(make_git_fixture)"
write_test_body "$R/tests/newflat.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
run_staged "$R" "tests/newflat.sh"
if [[ $RC -eq 1 && "$ERR" == *"FLAT_TEST_SH_REJECTED"* ]]; then
  pass "3a new flat tests/newflat.sh rejected (FLAT_TEST_SH_REJECTED) despite valid frontmatter"
else
  fail "3a new flat tests/newflat.sh rejected" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R"

# 3b: EXISTING flat file (committed to HEAD) then edited => grandfathered, NOT
# flat-rejected. git cat-file -e HEAD:<rel> succeeds, so the newness gate skips it.
R="$(make_git_fixture)"
write_test_body "$R/tests/legacy-flat.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q -m "seed legacy flat test" >/dev/null 2>&1
write_test_body "$R/tests/legacy-flat.sh" '# Tests: bin/foo.sh, bin/bar.sh' "$DEFAULT_TAGS"
run_staged "$R" "tests/legacy-flat.sh"
if [[ $RC -eq 0 && "$ERR" != *"FLAT_TEST_SH_REJECTED"* ]]; then
  pass "3b existing flat file grandfathered (no FLAT_TEST_SH_REJECTED on edit)"
else
  fail "3b existing flat file grandfathered" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R"

# 3c: NEW tests/run-all.sh (infra runner) => exempt from flat-rejection.
# Given valid frontmatter to isolate the exemption from check_content; the
# pre-commit filter additionally excludes run-all.sh from the checker entirely.
R="$(make_git_fixture)"
write_test_body "$R/tests/run-all.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
run_staged "$R" "tests/run-all.sh"
if [[ "$ERR" != *"FLAT_TEST_SH_REJECTED"* ]]; then
  pass "3c tests/run-all.sh exempt from flat-rejection (no FLAT_TEST_SH_REJECTED)"
else
  fail "3c tests/run-all.sh exempt from flat-rejection" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R"

# 3d: NEW 2-level tests/bin/twolevel.sh (valid) => accepted, not flat-rejected.
R="$(make_git_fixture)"
write_test_body "$R/tests/bin/twolevel.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
run_staged "$R" "tests/bin/twolevel.sh"
if [[ $RC -eq 0 && "$ERR" != *"FLAT_TEST_SH_REJECTED"* ]]; then
  pass "3d new 2-level tests/bin/ file accepted (no FLAT_TEST_SH_REJECTED)"
else
  fail "3d new 2-level tests/bin/ file accepted" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R"
case_end

case_begin "nonsh-placement" "bin/check-test-frontmatter.sh"
# --- #2392: .Tests.ps1 / test_*.py follow the same tests/<category>/ rule as .sh.
# write_nonsh_body <path> <tests-or-__NONE__> <tags-or-__NONE__> — '#' headers suit both.
write_nonsh_body() {
  mkdir -p "$(dirname "$1")"
  { [[ "$2" != "__NONE__" ]] && echo "$2"; [[ "$3" != "__NONE__" ]] && echo "$3"; echo '# body'; } > "$1"
}
# nonsh_staged <label> <relpath> <tests> <tags> <want-rc> <want-err-substr|__EMPTY__>
nonsh_staged() {
  R="$(make_git_fixture)"; mkdir -p "$R/tests/lib"; echo '# stub' > "$R/tests/lib/harness.sh"
  write_nonsh_body "$R/$2" "$3" "$4"; run_staged "$R" "$2"
  if [[ "$6" == "__EMPTY__" ]]; then [[ $RC -eq $5 && -z "$ERR" ]]; else [[ $RC -eq $5 && "$ERR" == *"$6"* ]]; fi \
    && pass "$1" || fail "$1" "rc=$RC err=<<$ERR>>"
  rm -rf "$R"
}
for nm in x.Tests.ps1 test_x.py; do
  # 7a new flat file => FLAT_TEST_REJECTED; 7b category file passes (harness.sh present, so the
  # .sh-only harness rule must not leak); 7c/7d category file IS validated.
  nonsh_staged "7a new flat tests/$nm rejected" "tests/$nm" '# Tests: bin/foo.sh' "$DEFAULT_TAGS" 1 FLAT_TEST_REJECTED
  nonsh_staged "7b tests/bin/$nm with full frontmatter passes" "tests/bin/$nm" '# Tests: bin/foo.sh' "$DEFAULT_TAGS" 0 __EMPTY__
  nonsh_staged "7c tests/bin/$nm missing Tests header" "tests/bin/$nm" '__NONE__' "$DEFAULT_TAGS" 1 MISSING_TESTS_HEADER
  nonsh_staged "7d tests/bin/$nm missing scope" "tests/bin/$nm" '# Tests: bin/foo.sh' '# Tags: TL2' 1 MISSING_SCOPE_TAG
  # 7e: EXISTING flat file (in HEAD) edited => grandfathered, no position-based rejection.
  R="$(make_git_fixture)"
  write_nonsh_body "$R/tests/$nm" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
  git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m seed >/dev/null 2>&1
  write_nonsh_body "$R/tests/$nm" '# Tests: bin/foo.sh, bin/bar.sh' "$DEFAULT_TAGS"
  run_staged "$R" "tests/$nm"
  [[ $RC -eq 0 && "$ERR" != *"FLAT_TEST"* ]] \
    && pass "7e existing flat tests/$nm grandfathered on edit" \
    || fail "7e existing flat tests/$nm grandfathered" "rc=$RC err=<<$ERR>>"
  rm -rf "$R"
done

# 7f: --all scans tests/<category>/*.Tests.ps1 and test_*.py and flags missing frontmatter.
R="$(make_git_fixture)"
write_nonsh_body "$R/tests/bin/bad.Tests.ps1" '__NONE__' "$DEFAULT_TAGS"
write_nonsh_body "$R/tests/install/test_bad.py" '# Tests: bin/foo.sh' '__NONE__'
run_all "$R"
[[ $RC -eq 1 && "$ERR" == *"MISSING_TESTS_HEADER: tests/bin/bad.Tests.ps1"* \
   && "$ERR" == *"MISSING_SCOPE_TAG: tests/install/test_bad.py"* ]] \
  && pass "7f --all flags frontmatter defects in category .Tests.ps1 and test_*.py" \
  || fail "7f --all scans category .Tests.ps1 / test_*.py" "rc=$RC err=<<$ERR>>"
rm -rf "$R"
case_end

case_begin "nonsh-non-entrypoint" "bin/check-test-frontmatter.sh"
# --- #2392: non-test entrypoints (helper.ps1, helper.py) must be ignored --------
# Files not matching *.Tests.ps1 or test_*.py are not test entrypoints and must
# never be validated or rejected by check-test-frontmatter.sh.

# NE1: staged tests/bin/helper.ps1 (not *.Tests.ps1) => ignored, rc=0, no error
R="$(make_git_fixture)"
mkdir -p "$R/tests/bin"
echo '# plain PS helper' > "$R/tests/bin/helper.ps1"
run_staged "$R" "tests/bin/helper.ps1"
if [[ $RC -eq 0 && -z "$ERR" ]]; then
  pass "NE1 staged tests/bin/helper.ps1 (not *.Tests.ps1) is ignored (rc=0, no error)"
else
  fail "NE1 staged tests/bin/helper.ps1 is ignored" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R"

# NE2: staged tests/bin/helper.py (not test_*.py) => ignored, rc=0, no error
R="$(make_git_fixture)"
mkdir -p "$R/tests/bin"
echo '# plain Python helper' > "$R/tests/bin/helper.py"
run_staged "$R" "tests/bin/helper.py"
if [[ $RC -eq 0 && -z "$ERR" ]]; then
  pass "NE2 staged tests/bin/helper.py (not test_*.py) is ignored (rc=0, no error)"
else
  fail "NE2 staged tests/bin/helper.py is ignored" "rc=$RC err=<<$ERR>>"
fi
rm -rf "$R"

# NE3: --all with helper.ps1 / helper.py alongside a valid .sh => exit 0
# (non-entrypoints are not scanned by the glob, so no frontmatter check fires).
R="$(make_git_fixture)"
write_test_body "$R/tests/bin/a.sh" '# Tests: bin/foo.sh' "$DEFAULT_TAGS"
echo '# plain PS helper' > "$R/tests/bin/helper.ps1"
echo '# plain Python helper' > "$R/tests/bin/helper.py"
run_all "$R"
if [[ $RC -eq 0 ]]; then
  pass "NE3 --all ignores helper.ps1/helper.py alongside valid .sh (rc=0)"
else
  fail "NE3 --all ignores helper.ps1/helper.py" "rc=$RC out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R"
case_end

# --- Summary ---------------------------------------------------------------
echo "1..$((PASS+FAIL))"
echo "# PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
