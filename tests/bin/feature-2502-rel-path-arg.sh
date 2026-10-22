#!/usr/bin/env bash
# tests/bin/feature-2502-rel-path-arg.sh
# Tests: bin/check-case-markers.sh, bin/check-self-impl.sh, bin/check-test-language-match.sh
# Tags: TL2, bin, case-markers, self-impl, test-language-match, scope:issue-specific
# Issue #2502 S3-0: the three test checks take the original path as --rel <rel> when they read
# a temp copy. The copy is copy.tmp in the x dir under <tmp>, a name no registry entry matches: with
# --rel tests/bin/test_foo.py each CLI judges it as pytest and prints the rel path, never the
# temp path. Without --rel the file's own path is used, as today. --rel or --head with two
# files is an infra error (exit 2). The language-match CLI is also driven as pester and js.
# With --head it reports only a mismatch HEAD lacks; an empty value or a missing head copy is exit 2.
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
harness_isolate "$TMPBASE/iso"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE

CM_CLI="$SCRIPT_CHECKOUT_ROOT/bin/check-case-markers.sh"
SI_CLI="$SCRIPT_CHECKOUT_ROOT/bin/check-self-impl.sh"
LM_CLI="$SCRIPT_CHECKOUT_ROOT/bin/check-test-language-match.sh"
REL=tests/bin/test_foo.py

REPO="$TMPBASE/repo"
harness_git_init "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
git -C "$REPO" config core.autocrlf false
mkdir -p "$REPO/tests/lib" "$REPO/tests/bin" "$REPO/bin"
for _ext in sh ps1 py js; do
  printf '\n' > "$REPO/tests/lib/harness.$_ext"
  printf '\n' > "$REPO/bin/a.$_ext"
done
printf '\n' > "$REPO/bin/b.py"
printf '\n' > "$REPO/bin/foo.js"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -q -m init >/dev/null 2>&1

BODIES="$TMPBASE/bodies"
mkdir -p "$BODIES"
# Two Tests: paths, no case markers.
printf '%s\n' '# Tests: bin/a.py, bin/b.py' '# Tags: scope:common' 'import pytest' '' '' \
  'def test_a():' '    assert pytest is not None' > "$BODIES/py-missing"
# A hand-made counter on line 3 and a redefinition of the helper's isolate on line 6.
printf '%s\n' '# Tests: bin/a.py' '# Tags: scope:common' 'passed = 0' '' '' \
  'def isolate():' '    return None' > "$BODIES/py-selfimpl"
# A pytest test whose only target is JavaScript code.
printf '%s\n' '# Tests: bin/foo.js' '# Tags: scope:common' 'import pytest' '' '' \
  'def test_a():' '    assert pytest is not None' > "$BODIES/py-mismatch"

# copy_as <body> — the body as copy.tmp in the x dir under <tmp>, outside the repo; echoes that path.
copy_as() {
  mkdir -p "$TMPBASE/x"
  cp "$BODIES/$1" "$TMPBASE/x/copy.tmp"
  printf '%s' "$TMPBASE/x/copy.tmp"
}

# named <body> — the body at tests/bin/test_foo.py inside the repo.
named() {
  cp "$BODIES/$1" "$REPO/$REL"
}

# run_cli <cli> <arg>... — <cli> with the repo root as cwd. Sets R_RC R_OUT R_ERR.
R_RC=0; R_OUT=""; R_ERR=""
run_cli() {
  local cli="$1"
  shift
  R_RC=0
  (
    cd "$REPO" || exit 99
    bash "$RWT" 90 bash "$cli" "$@"
  ) >"$TMPBASE/r.out" 2>"$TMPBASE/r.err" || R_RC=$?
  R_OUT="$(cat "$TMPBASE/r.out")"
  R_ERR="$(cat "$TMPBASE/r.err")"
}

expect_rc() {
  if [ "$3" = "$2" ]; then pass "$1: rc=$2"; else fail "$1" "want rc=$2 got rc=$3: $R_OUT $R_ERR"; fi
}
has() {
  case "$2" in *"$3"*) pass "$1: has [$3]" ;; *) fail "$1" "lacks [$3]: $2" ;; esac
}
lacks() {
  case "$2" in *"$3"*) fail "$1" "must not mention [$3]: $2" ;; *) pass "$1: no [$3]" ;; esac
}
# every_line_starts <label> <text> <prefix> — non-empty, and every line starts with <prefix>.
every_line_starts() {
  local line bad=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "${line#"$3"}" != "$line" ] || bad="$bad[$line]"
  done <<< "$2"
  if [ -z "$2" ]; then fail "$1" "no output"; elif [ -z "$bad" ]; then pass "$1: every line starts [$3]"; else fail "$1" "$bad"; fi
}

MARKER_NAME="$(node -e 'const t=require(process.argv[1]);const e=t.entries.find(x=>x.id==="pytest");process.stdout.write(String(((e||{}).diagnostics||{}).markerName||""))' "$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/test-language-registry.json")")"

case_begin "rel-case-markers-judges-as-pytest" "bin/check-case-markers.sh"
_copy="$(copy_as py-missing)"
run_cli "$CM_CLI" --rel "$REL" "$_copy"
expect_rc "check-case-markers --rel" 1 "$R_RC"
every_line_starts "check-case-markers --rel" "$R_OUT" "HIGH: $REL ("
has "check-case-markers --rel" "$R_OUT" "no $MARKER_NAME markers) code=MISSING_CASE_MARKERS"
lacks "check-case-markers --rel" "$R_OUT$R_ERR" "copy.tmp"
_with_rel="$R_OUT"
named py-missing
run_cli "$CM_CLI" "$REL"
expect_rc "check-case-markers, own path" 1 "$R_RC"
assert_eq "$R_OUT" "$_with_rel"
run_cli "$CM_CLI" "$_copy"
expect_rc "check-case-markers, copy without --rel" 0 "$R_RC"
lacks "check-case-markers, copy without --rel" "$R_OUT" "HIGH:"
case_end

case_begin "rel-self-impl-judges-as-pytest" "bin/check-self-impl.sh"
if command -v uv >/dev/null 2>&1; then
  _copy="$(copy_as py-selfimpl)"
  run_cli "$SI_CLI" --rel "$REL" "$_copy"
  expect_rc "check-self-impl --rel" 1 "$R_RC"
  every_line_starts "check-self-impl --rel" "$R_OUT" "HIGH: $REL line "
  has "check-self-impl --rel" "$R_OUT" "HIGH: $REL line 6: self-implemented harness (harness-redef isolate) code=SELF_IMPLEMENTED_HARNESS"
  lacks "check-self-impl --rel" "$R_OUT$R_ERR" "copy.tmp"
  _with_rel="$R_OUT"
  named py-selfimpl
  run_cli "$SI_CLI" "$REL"
  expect_rc "check-self-impl, own path" 1 "$R_RC"
  assert_eq "$R_OUT" "$_with_rel"
  run_cli "$SI_CLI" "$_copy"
  expect_rc "check-self-impl, copy without --rel" 0 "$R_RC"
  lacks "check-self-impl, copy without --rel" "$R_OUT" "HIGH:"
else
  skip "check-self-impl --rel: uv not installed"
fi
case_end

case_begin "rel-language-match-judges-as-pytest" "bin/check-test-language-match.sh"
_copy="$(copy_as py-mismatch)"
run_cli "$LM_CLI" --rel "$REL" "$_copy"
expect_rc "check-test-language-match --rel" 1 "$R_RC"
every_line_starts "check-test-language-match --rel" "$R_OUT" "HIGH: $REL"
has "check-test-language-match --rel" "$R_OUT" "test language pytest does not match code language js of bin/foo.js (new file shape: "
has "check-test-language-match --rel" "$R_OUT" "code=TEST_LANGUAGE_MISMATCH"
lacks "check-test-language-match --rel" "$R_OUT$R_ERR" "copy.tmp"
_with_rel="$R_OUT"
named py-mismatch
run_cli "$LM_CLI" "$REL"
expect_rc "check-test-language-match, own path" 1 "$R_RC"
assert_eq "$R_OUT" "$_with_rel"
case_end

# rel_lm <label> <rel> <body> <want-rc> [<mismatch-text>] — check-test-language-match on the
# copy with --rel <rel>: rc, no temp path, and either the mismatch text or no output at all.
rel_lm() {
  _copy="$(copy_as "$3")"
  run_cli "$LM_CLI" --rel "$2" "$_copy"
  expect_rc "$1" "$4" "$R_RC"
  lacks "$1" "$R_OUT$R_ERR" "copy.tmp"
  if [ -n "${5:-}" ]; then
    every_line_starts "$1" "$R_OUT" "HIGH: $2"
    has "$1" "$R_OUT" "$5"
  else
    assert_eq "$1: output=[$R_OUT]" "$1: output=[]"
  fi
}
printf '%s\n' '# Tests: bin/foo.js' '# Tags: scope:common' "Describe 'a' {" "    It 'runs' { 1 | Should -Be 1 }" '}' > "$BODIES/ps-mismatch"
printf '%s\n' '# Tests: bin/a.ps1' '# Tags: scope:common' "Describe 'a' {" "    It 'runs' { 1 | Should -Be 1 }" '}' > "$BODIES/ps-same"
printf '%s\n' '"use strict";' '// Tests: bin/a.py' '// Tags: scope:common' 'const { test } = require("node:test");' 'test("a", () => {});' > "$BODIES/js-mismatch"
printf '%s\n' '"use strict";' '// Tests: bin/foo.js' '// Tags: scope:common' 'const { test } = require("node:test");' 'test("a", () => {});' > "$BODIES/js-same"
printf '%s\n' '# Tests: bin/a.py' '# Tags: scope:common' '' '' 'def test_a():' '    assert True' > "$BODIES/py-same"

case_begin "rel-language-match-judges-as-pester" "bin/check-test-language-match.sh"
rel_lm "pester --rel on js code" tests/bin/foo.Tests.ps1 ps-mismatch 1 "test language pester does not match code language js of bin/foo.js (new file shape: "
rel_lm "pester --rel on ps1 code" tests/bin/foo.Tests.ps1 ps-same 0
case_end

case_begin "rel-language-match-judges-as-js" "bin/check-test-language-match.sh"
rel_lm "js --rel on python code" tests/bin/foo.js js-mismatch 1 "test language js does not match code language pytest of bin/a.py (new file shape: "
rel_lm "js --rel on js code" tests/bin/foo.js js-same 0
case_end

case_begin "rel-language-match-pytest-same-language" "bin/check-test-language-match.sh"
rel_lm "pytest --rel on python code" "$REL" py-same 0
case_end

case_begin "rel-with-two-files-is-infra-error" "bin/check-case-markers.sh"
named py-missing
_copy="$(copy_as py-missing)"
run_cli "$CM_CLI" --rel "$REL" "$_copy" "$REL"
expect_rc "check-case-markers --rel + 2 files" 2 "$R_RC"
case_end

case_begin "rel-with-two-files-is-infra-error-self-impl" "bin/check-self-impl.sh"
run_cli "$SI_CLI" --rel "$REL" "$_copy" "$REL"
expect_rc "check-self-impl --rel + 2 files" 2 "$R_RC"
case_end

case_begin "rel-and-head-with-two-files-are-infra-errors" "bin/check-test-language-match.sh"
run_cli "$LM_CLI" --rel "$REL" "$_copy" "$REL"
expect_rc "check-test-language-match --rel + 2 files" 2 "$R_RC"
run_cli "$LM_CLI" --head "$_copy" "$_copy" "$REL"
expect_rc "check-test-language-match --head + 2 files" 2 "$R_RC"
case_end

# rel_head_lm <label> <head-body> <edited-body> <want-rc> [<mismatch-text>] — --rel with --head:
# head.tmp (the HEAD body) is the baseline, copy.tmp (the edited body) the version judged.
printf '%s\n' '# Tests: bin/a.py' '# Tags: scope:common' 'import pytest' '' '' 'def test_a():' '    assert pytest is not None' > "$BODIES/py-a"
rel_head_lm() {
  _copy="$(copy_as "$3")"
  cp "$BODIES/$2" "$TMPBASE/x/head.tmp"
  run_cli "$LM_CLI" --rel "$REL" --head "$TMPBASE/x/head.tmp" "$_copy"
  expect_rc "$1" "$4" "$R_RC"
  lacks "$1" "$R_OUT$R_ERR" ".tmp"
  if [ -n "${5:-}" ]; then
    every_line_starts "$1" "$R_OUT" "HIGH: $REL"
    has "$1" "$R_OUT" "$5"
  else
    assert_eq "$1: output=[$R_OUT]" "$1: output=[]"
  fi
}

case_begin "rel-with-head-judges-against-head" "bin/check-test-language-match.sh"
rel_head_lm "head on python, edited on js: new mismatch" py-a py-mismatch 1 "test language pytest does not match code language js of bin/foo.js (new file shape: "
rel_head_lm "head and edited both on js: existing state" py-mismatch py-mismatch 0
rel_head_lm "head on js, edited on python: fixed" py-mismatch py-a 0
case_end

# usage_err <label> <cli> <want-stderr> <arg>... — exit 2, <want-stderr> on stderr, no stdout.
usage_err() {
  local label="$1" cli="$2" want="$3"
  shift 3
  run_cli "$cli" "$@"
  expect_rc "$label" 2 "$R_RC"
  has "$label" "$R_ERR" "$want"
  assert_eq "$label stdout=[$R_OUT]" "$label stdout=[]"
}

case_begin "rel-value-missing-or-empty-case-markers" "bin/check-case-markers.sh"
usage_err "check-case-markers --rel without value" "$CM_CLI" "check-case-markers.sh: --rel needs a value" --rel
usage_err "check-case-markers --rel empty" "$CM_CLI" "check-case-markers.sh: --rel needs a value" --rel "" "$_copy"
case_end

case_begin "rel-value-missing-or-empty-self-impl" "bin/check-self-impl.sh"
usage_err "check-self-impl --rel without value" "$SI_CLI" "check-self-impl.sh: --rel needs a value" --rel
usage_err "check-self-impl --rel empty" "$SI_CLI" "check-self-impl.sh: --rel needs a value" --rel "" "$_copy"
case_end

case_begin "rel-and-head-value-errors-language-match" "bin/check-test-language-match.sh"
usage_err "check-test-language-match --rel without value" "$LM_CLI" "check-test-language-match.sh: --rel needs a value" "$_copy" --rel
usage_err "check-test-language-match --rel empty" "$LM_CLI" "check-test-language-match.sh: --rel needs a value" --rel "" "$_copy"
usage_err "check-test-language-match --head empty" "$LM_CLI" "check-test-language-match.sh: --head needs a value" --head "" "$_copy"
usage_err "check-test-language-match --head copy absent" "$LM_CLI" "check-test-language-match.sh: head copy not found: $TMPBASE/x/no-head.tmp" --rel "$REL" --head "$TMPBASE/x/no-head.tmp" "$_copy"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
