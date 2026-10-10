#!/usr/bin/env bash
# tests/bin/bin-select-tests-stem.sh
# Tests: bin/lib/select-tests-stem.sh, bin/select-tests.sh
# Tags: select-tests, stem, sweep-tests, TL2, scope:common
# TL3 gap (what this test does NOT catch):
# - stems from a real multi-commit feature diff rather than one-file fixture commits
# - bash 3.x (macOS default) parsing of the extracted library
# Closest-to-action mitigation: none needed — selection only, every stem rule is pinned here.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/test-language-registry-fixture.sh"

ROOT="$(make_tmp)"
trap 'rm -rf "$ROOT"' EXIT
harness_isolate "$ROOT/iso"
export HOME="$ROOT/home" NO_LOG=true
mkdir -p "$HOME" "$ROOT/work"
cd "$ROOT/work" || exit 1

STS_REL="bin/lib/select-tests-stem.sh"
# shellcheck source=/dev/null
[ -f "$SCRIPT_CHECKOUT_ROOT/$STS_REL" ] && . "$SCRIPT_CHECKOUT_ROOT/$STS_REL"

sts_ready() {
  declare -F sts_stems_of_path >/dev/null && declare -F sts_name_matches >/dev/null && return 0
  fail "$1" "sts_stems_of_path / sts_name_matches not defined (not implemented: $STS_REL)"
  return 1
}
# stems_csv <path> — STS_STEMS for <path>, comma-joined in emitted order; "-" when none.
stems_csv() {
  local IFS=,
  sts_stems_of_path "$1"
  if [ "${#STS_STEMS[@]}" -eq 0 ]; then printf -- '-'; else printf '%s' "${STS_STEMS[*]}"; fi
}

case_begin "stem-rules-table" "bin/lib/select-tests-stem.sh"
if sts_ready "stem-rules-table"; then
  while IFS='|' read -r name path want; do
    [ -n "$name" ] || continue
    got="$(stems_csv "$path")"
    if [ "$got" = "$want" ]; then pass "stem-rules-table/$name: $path -> $want"; else fail "stem-rules-table/$name" "path='$path' want='$want' got='$got'"; fi
  done <<'ROWS'
skill-md|skills/run-tests/SKILL.md|run-tests
skill-md-nested|skills/a/b/SKILL.md|a/b
skill-md-under-scripts|skills/x/scripts/SKILL.md|x/scripts
script-area-then-file|skills/sweep-tests/scripts/run.sh|sweep-tests,run
script-last-ext-only|skills/sweep-tests/scripts/a.b.sh|sweep-tests,a.b
script-short-file-dropped|skills/sweep-tests/scripts/ab.sh|sweep-tests
script-short-area-kept|skills/ab/scripts/runner.sh|ab,runner
script-no-ext|skills/issue-close/scripts/finalize|issue-close,finalize
script-nested-dir|skills/sweep-tests/scripts/sub/x-y.sh|sweep-tests,x-y
skill-other-file|skills/run-tests/README.md|-
agent-md|agents/survey-code.md|survey-code
agent-non-md|agents/notes.txt|-
hook-js|hooks/block-case-markers.js|block-case-markers
hook-lib-js|hooks/lib/foo-bar.js|lib/foo-bar
hook-no-ext|hooks/pre-commit|-
hook-sh|hooks/foo.sh|-
bin-sh|bin/select-tests.sh|select-tests
bin-lib-basename|bin/lib/run-all-durations.sh|run-all-durations
bin-no-ext|bin/get-config-var|get-config-var
bin-last-ext-only|bin/step-durations.test.js|step-durations.test
bin-two-chars-dropped|bin/ab.sh|-
bin-three-chars-kept|bin/abc.sh|abc
bin-dotfile-empty|bin/.env|-
docs-ignored|docs/history.md|-
tests-ignored|tests/bin/foo.sh|-
prefix-not-anchored|src/bin/foo.sh|-
space-kept|bin/my tool.sh|my tool
ROWS
fi
case_end

case_begin "metachar-path-is-data" "bin/lib/select-tests-stem.sh"
if sts_ready "metachar-path-is-data"; then
  # shellcheck disable=SC2016  # the literal $( ) is the hostile input under test.
  got="$(stems_csv 'bin/$(touch pwned)`touch pwned`.sh')"
  if [ ! -e "$ROOT/work/pwned" ] && [ "$got" = '$(touch pwned)`touch pwned`' ]; then
    pass "metachar-path-is-data: stem kept verbatim, nothing executed"
  else
    fail "metachar-path-is-data" "marker=$([ -e "$ROOT/work/pwned" ] && echo created || echo absent) got='$got'"
  fi
fi
case_end

case_begin "empty-path-no-stems" "bin/lib/select-tests-stem.sh"
if sts_ready "empty-path-no-stems"; then
  got="$(stems_csv '')"
  if [ "$got" = "-" ]; then pass "empty-path-no-stems"; else fail "empty-path-no-stems" "got='$got'"; fi
fi
case_end

case_begin "repeat-call-resets-stems" "bin/lib/select-tests-stem.sh"
if sts_ready "repeat-call-resets-stems"; then
  sts_stems_of_path skills/sweep-tests/scripts/run.sh
  sts_stems_of_path docs/x.md
  n1="${#STS_STEMS[@]}"
  sts_stems_of_path bin/select-tests.sh
  got="${STS_STEMS[*]}"
  if [ "$n1" -eq 0 ] && [ "$got" = "select-tests" ]; then
    pass "repeat-call-resets-stems: each call starts from an empty STS_STEMS (no subshell needed)"
  else
    fail "repeat-call-resets-stems" "after docs/x.md count=$n1; after bin/select-tests.sh '$got'"
  fi
fi
case_end

case_begin "name-matches-table" "bin/lib/select-tests-stem.sh"
if sts_ready "name-matches-table"; then
  while IFS='|' read -r base stem want; do
    [ -n "$base" ] || continue
    if sts_name_matches "$base" "$stem"; then got=match; else got=miss; fi
    if [ "$got" = "$want" ]; then pass "name-matches-table: '$base' ~ '$stem' -> $want"; else fail "name-matches-table" "'$base' ~ '$stem' want=$want got=$got"; fi
  done <<'ROWS'
feature-run-tests-x.sh|run-tests|match
run-tests.sh|run-tests|match
runtests.sh|run-tests|miss
foo.sh|lib/foo|miss
abc.sh|a*c|miss
a*c.sh|a*c|match
x[ab]y.sh|[ab]|match
xay.sh|[ab]|miss
xy?.sh|y?|match
xyz.sh|y?|miss
Run-Tests.sh|run-tests|miss
ROWS
fi
case_end

# The selector end to end: one fixture commit per changed path, against a fixed fake tests/bin.
FAKE="$ROOT/fake"
FREPO="$ROOT/frepo"
mkdir -p "$FAKE/bin/lib" "$FAKE/tests/bin"
cp "$SCRIPT_CHECKOUT_ROOT/bin/select-tests.sh" "$FAKE/bin/select-tests.sh"
[ -f "$SCRIPT_CHECKOUT_ROOT/$STS_REL" ] && cp "$SCRIPT_CHECKOUT_ROOT/$STS_REL" "$FAKE/$STS_REL"
install_test_language_registry "$FAKE" "$SCRIPT_CHECKOUT_ROOT" || fail "fixture" "registry install failed"
for n in feature-run-tests-a.sh bin-sweep-tests-b.sh lab-z.sh hook-block-case-markers-d.sh \
  survey-code-e.sh select-tests-f.sh ab-short.sh runner-h.sh unrelated-g.sh; do
  : >"$FAKE/tests/bin/$n"
done
harness_git_init "$FREPO"
git -C "$FREPO" config user.email t@example.com
git -C "$FREPO" config user.name T
: >"$FREPO/README.md"
git -C "$FREPO" add -A
git -C "$FREPO" commit -q -m base
git -C "$FREPO" branch -f base HEAD

# selected_for <path> — basenames the selector picks for a diff touching only <path>.
selected_for() {
  git -C "$FREPO" checkout -q -B probe base
  mkdir -p "$FREPO/$(dirname "$1")"
  echo change >"$FREPO/$1"
  git -C "$FREPO" add -A
  git -C "$FREPO" commit -q -m probe
  (cd "$FREPO" && run_with_timeout 120 bash "$FAKE/bin/select-tests.sh" base HEAD 2>/dev/null) \
    | sed 's#.*/##' | LC_ALL=C sort | tr '\n' ' '
}

case_begin "selector-behaviour-unchanged" "bin/select-tests.sh"
while IFS='|' read -r path want; do
  [ -n "$path" ] || continue
  got="$(selected_for "$path")"
  got="${got% }"
  if [ "$got" = "$want" ]; then pass "selector-behaviour-unchanged: $path -> ${want:-(none)}"; else fail "selector-behaviour-unchanged" "$path want='$want' got='$got'"; fi
done <<'ROWS'
skills/run-tests/SKILL.md|feature-run-tests-a.sh
skills/sweep-tests/scripts/run.sh|bin-sweep-tests-b.sh feature-run-tests-a.sh runner-h.sh
skills/ab/scripts/runner.sh|ab-short.sh lab-z.sh runner-h.sh
agents/survey-code.md|survey-code-e.sh
hooks/block-case-markers.js|hook-block-case-markers-d.sh
bin/select-tests.sh|select-tests-f.sh
bin/ab.sh|
docs/x.md|
ROWS
case_end

case_begin "selector-uses-stem-lib" "bin/select-tests.sh"
if grep -q 'select-tests-stem\.sh' "$SCRIPT_CHECKOUT_ROOT/bin/select-tests.sh" && ! grep -q 'skills/\*/scripts/\*)' "$SCRIPT_CHECKOUT_ROOT/bin/select-tests.sh"; then
  pass "selector-uses-stem-lib: select-tests.sh sources the stem lib and keeps no copy of the rules"
else
  fail "selector-uses-stem-lib" "bin/select-tests.sh does not source $STS_REL, or still carries its own stem case arms"
fi
case_end

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
