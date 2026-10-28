#!/usr/bin/env bash
# Tests: bin/review-scope-header-targets.sh
# Tags: review-tests, scope-delta, header-targets, cli, TL2, scope:issue-specific
#
# Exit 3 of bin/review-scope-header-targets.sh: a copy whose bin/lib/test-frontmatter-fix.sh is
# missing (E1), or whose libraries load but whose registry (hooks/lib) is unreachable (E3).
# E2 runs the same input against the in-repo script, so the fixture itself is known valid.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

TARGET="bin/review-scope-header-targets.sh"
REAL_SCRIPT="$SCRIPT_CHECKOUT_ROOT/$TARGET"
LOAD_ERR="review-scope-header-targets: cannot load bin/lib/test-frontmatter-fix.sh or the test-language registry"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT"
cd "$TMP_ROOT" || exit 1

FIXTURE_ROOT="$TMP_ROOT/root"
mkdir -p "$FIXTURE_ROOT/tests"
printf '#!/usr/bin/env bash\n# Tests: bin/foo.sh\n# Tags: scope:issue-specific\n' >"$FIXTURE_ROOT/tests/sample.sh"
INPUT_FILE="$TMP_ROOT/input.bin"
printf 'tests/sample.sh\0' >"$INPUT_FILE"

# run_script <script> <tag> — sets RC; stdout/stderr land in $TMP_ROOT/<tag>.out / .err.
run_script() {
  RC=0
  run_with_timeout 60 bash "$1" "$FIXTURE_ROOT" <"$INPUT_FILE" >"$TMP_ROOT/$2.out" 2>"$TMP_ROOT/$2.err" || RC=$?
}

assert_exit3() {
  local tag="$1"
  assert_eq "$RC" "3"
  if grep -qF "$LOAD_ERR" "$TMP_ROOT/$tag.err"; then
    pass "$tag: stderr carries the load-failure line"
  else
    fail "$tag: stderr lacks the load-failure line" "$(head -c 400 "$TMP_ROOT/$tag.err")"
  fi
  if [[ -s "$TMP_ROOT/$tag.out" ]]; then
    fail "$tag: stdout not empty" "$(tr '\0' '|' <"$TMP_ROOT/$tag.out")"
  else
    pass "$tag: stdout empty"
  fi
}

case_begin "E1 library missing beside the script copy exits 3" "$TARGET"
mkdir -p "$TMP_ROOT/e1/bin"
cp "$REAL_SCRIPT" "$TMP_ROOT/e1/bin/"
run_script "$TMP_ROOT/e1/bin/review-scope-header-targets.sh" e1
assert_exit3 e1
case_end

case_begin "E2 control: the same input against the in-repo script exits 0" "$TARGET"
run_script "$REAL_SCRIPT" e2
assert_eq "$RC" "0"
assert_eq "$(tr '\0' '|' <"$TMP_ROOT/e2.out")" "tests/sample.sh|1|bin/foo.sh|"
case_end

case_begin "E3 libraries present but the registry unreachable exits 3" "$TARGET"
mkdir -p "$TMP_ROOT/e3/bin/lib"
cp "$REAL_SCRIPT" "$TMP_ROOT/e3/bin/"
cp "$SCRIPT_CHECKOUT_ROOT/bin/test-language-registry" "$TMP_ROOT/e3/bin/"
for lib in test-frontmatter-fix.sh test-frontmatter-constants.sh test-language-registry.sh; do
  cp "$SCRIPT_CHECKOUT_ROOT/bin/lib/$lib" "$TMP_ROOT/e3/bin/lib/"
done
run_script "$TMP_ROOT/e3/bin/review-scope-header-targets.sh" e3
assert_exit3 e3
if grep -qF "[test-language-registry] cannot load" "$TMP_ROOT/e3.err"; then
  pass "e3: the registry loader reported the unreachable table"
else
  fail "e3: registry loader line missing" "$(head -c 400 "$TMP_ROOT/e3.err")"
fi
case_end

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
