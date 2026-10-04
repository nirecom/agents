#!/usr/bin/env bash
# tests/tests/test-language-registry-residue.sh
# Tests: hooks/lib/test-language-registry.json, bin/lib/run-all-launch.sh
# Tags: TL2, tests, test-language-registry, residue, scope:common
# Language knowledge (pattern words, entry names, id comparisons) lives only in the test
# language registry and its registered parts; scan.js finds what is left anywhere else.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

TMPBASE="$(make_tmp)"
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
cd "$TMPBASE" || exit 1
RD="$AGENTS_DIR/tests/tests/test-language-registry-residue"
FXD="$RD/fixtures"
FX_TABLE="$FXD/table.json"

# scan <root> <table> [<allowlist>] — sets SC_OUT / SC_RC.
scan() {
  SC_RC=0
  SC_OUT="$(node "$RD/scan.js" --root "$1" --table "$2" ${3:+--allowlist "$3"} 2>&1)" || SC_RC=$?
}

# fx_unpack <file.fx> <dir> — `=== <path>` sections become files of a git repo at <dir>;
# `=== @allowlist` becomes <dir>.allow.
fx_unpack() {
  local out="" line
  mkdir -p "$2"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "=== @allowlist") out="$2.allow"; : >"$out"; continue ;;
      "=== "*) out="$2/${line#=== }"; mkdir -p "$(dirname "$out")"; : >"$out"; continue ;;
    esac
    if [ -n "$out" ]; then printf '%s\n' "$line" >>"$out"; fi
  done <"$1"
  harness_git_init "$2"
  git -C "$2" config core.autocrlf false
  git -C "$2" add -A
}

# fx_result <fail/name|pass/name> — unpack and scan fixtures/<rel>.fx once with the fixture
# table (and its allowlist, if any); later calls reuse the result. Sets SC_OUT / SC_RC.
fx_result() {
  local d="$TMPBASE/fx/${1//\//-}"
  if [ ! -f "$d.rc" ]; then
    fx_unpack "$FXD/$1.fx" "$d"
    if [ -f "$d.allow" ]; then scan "$d" "$FX_TABLE" "$d.allow"; else scan "$d" "$FX_TABLE"; fi
    printf '%s\n' "$SC_OUT" >"$d.out"
    printf '%s' "$SC_RC" >"$d.rc"
  fi
  SC_OUT="$(cat "$d.out")"
  SC_RC="$(cat "$d.rc")"
}

case_begin "words-derived-from-table" "hooks/lib/test-language-registry.json"
words() { node "$RD/scan.js" --root "$TMPBASE" --table "$1" --print-words | awk -F'\t' -v k="$2" '$1==k{print $2}' | LC_ALL=C sort | tr '\n' ' '; }
assert_eq "pattern words: $(words "$FX_TABLE" pattern)" "pattern words: .Tests.ps1 .js .py .sh .spec. .test. _test. test_ "
assert_eq "name words: $(words "$FX_TABLE" name)" "name words: bash pester pytest "
node -e 'const f=require("fs");const t=JSON.parse(f.readFileSync(process.argv[1],"utf8"));t.entries.push({id:"fakelang",status:"supported",patterns:["*.fakelang"]});f.writeFileSync(process.argv[2],JSON.stringify(t));' "$FX_TABLE" "$TMPBASE/table-plus.json"
assert_eq "added entry: $(words "$TMPBASE/table-plus.json" pattern | tr ' ' '\n' | grep -c fakelang) $(words "$TMPBASE/table-plus.json" name)" "added entry: 1 bash fakelang pester pytest "
case_end

case_begin "fixture-table" "bin/lib/run-all-launch.sh"
# name | fixture | want rc | has (token printed) / lacks (never printed) / - (rc only) | token
: >"$TMPBASE/rows"
while IFS='|' read -r name fx rc check tok; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; fx="${fx//[[:space:]]/}"; rc="${rc//[[:space:]]/}"; check="${check//[[:space:]]/}"
  tok="$(printf '%s' "$tok" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf '%s\n' "$fx" >>"$TMPBASE/rows"
  if [ ! -f "$FXD/$fx.fx" ]; then fail "$name" "fixture $fx.fx is missing"; continue; fi
  fx_result "$fx"
  got="rc=$SC_RC"
  if [ "$check" != "-" ]; then
    if printf '%s\n' "$SC_OUT" | grep -qF -- "$tok"; then got="$got has"; else got="$got lacks"; fi
  fi
  want="rc=$rc"
  [ "$check" = "-" ] || want="$want $check"
  if [ "$got" = "$want" ]; then pass "$name: $want [$tok]"; else fail "$name: want $want [$tok]" "got $got | $(printf '%s' "$SC_OUT" | tr '\n' '|')"; fi
done <<'TABLE'
old-launch-arm18     | fail/old-launch          | 1 | has   | a-pattern bin/lib/run-all-launch.sh:18
old-launch-arm25     | fail/old-launch          | 1 | has   | a-pattern bin/lib/run-all-launch.sh:25
run-all-globs-a      | fail/run-all-globs       | 1 | has   | a-pattern tests/run-all.sh:4
run-all-globs-b      | fail/run-all-globs       | 1 | has   | b-location tests/run-all.sh:4
precommit-enum-3     | fail/precommit-enum      | 1 | has   | a-pattern hooks/lib/precommit-tests-frontmatter.sh:3
precommit-enum-4     | fail/precommit-enum      | 1 | has   | b-location hooks/lib/precommit-tests-frontmatter.sh:4
precommit-enum-7     | fail/precommit-enum      | 1 | has   | a-pattern hooks/lib/precommit-tests-frontmatter.sh:7
python-rglob-b       | fail/python-rglob        | 1 | has   | b-location bin/normalize-harness-position.py:3
python-rglob-no-a    | fail/python-rglob        | 1 | lacks | a-pattern
triple-strip         | fail/triple-strip        | 1 | has   | a-pattern bin/lib/test-retire-predicate.sh:3
rules-paths-b        | fail/rules-paths         | 1 | has   | b-location rules/test/fixture-isolation.md:4
rules-paths-body     | fail/rules-paths         | 1 | lacks | a-pattern
table-driven-case-3  | fail/table-driven-case   | 1 | has   | a-pattern bin/check-table-driven.sh:3
table-driven-case-6  | fail/table-driven-case   | 1 | has   | a-pattern bin/check-table-driven.sh:6
id-compare-sh-2      | fail/id-compare          | 1 | has   | c-id-compare bin/lib/launch-pick.sh:2
id-compare-sh-5      | fail/id-compare          | 1 | has   | c-id-compare bin/lib/launch-pick.sh:5
id-compare-js-2      | fail/id-compare          | 1 | has   | c-id-compare hooks/lib/kind.js:2
id-compare-js-3      | fail/id-compare          | 1 | has   | c-id-compare hooks/lib/kind.js:3
name-words-line1     | fail/name-words          | 1 | has   | a-name hooks/lib/runner-kind.js:1
name-words-shell     | fail/name-words          | 1 | lacks | a-name hooks/lib/runner-kind.js:2
name-list-multiline  | fail/name-list           | 1 | has   | a-name hooks/lib/runner-map.js:2 pester,pytest
name-object-keys     | fail/name-object         | 1 | has   | a-name hooks/lib/runner-table.js:2 bash,pester,pytest
lang-key-js-2        | fail/lang-key-compare    | 1 | has   | c-id-compare hooks/lib/lang-pick.js:2
lang-key-js-3        | fail/lang-key-compare    | 1 | has   | c-id-compare hooks/lib/lang-pick.js:3
lang-key-js-4        | fail/lang-key-compare    | 1 | has   | c-id-compare hooks/lib/lang-pick.js:4
lang-key-sh-2        | fail/lang-key-compare    | 1 | has   | c-id-compare bin/lib/lang-pick.sh:2
lang-key-sh-3        | fail/lang-key-compare    | 1 | has   | c-id-compare bin/lib/lang-pick.sh:3
discovery-root-a     | fail/test-discovery-glob | 1 | has   | a-pattern bin/collect-tests.sh:1
discovery-root-b     | fail/test-discovery-glob | 1 | has   | b-location bin/collect-tests.sh:1
discovery-find-b     | fail/test-discovery-glob | 1 | has   | b-location bin/collect-tests.sh:2
discovery-glob-text  | fail/test-discovery-glob | 1 | has   | b-location bin/collect-tests.sh:3
rel-test-only-ps1    | fail/relative-test-only-glob | 1 | has   | b-location bin/run-category-tests.sh:2
rel-test-only-py     | fail/relative-test-only-glob | 1 | has   | b-location bin/run-category-tests.sh:3
rel-test-only-mixed  | fail/relative-test-only-glob | 1 | has   | a-pattern bin/run-category-tests.sh:2
rel-source-ext-free  | fail/relative-test-only-glob | 1 | lacks | bin/run-category-tests.sh:4
tool-compare-js-2    | fail/tool-compare        | 1 | has   | c-id-compare hooks/lib/runner-pick.js:2
tool-compare-js-3    | fail/tool-compare        | 1 | has   | c-id-compare hooks/lib/runner-pick.js:3
tool-compare-sh-2    | fail/tool-compare        | 1 | has   | c-id-compare bin/lib/tool-pick.sh:2
tool-compare-sh-3    | fail/tool-compare        | 1 | has   | c-id-compare bin/lib/tool-pick.sh:3
part-outside-a       | fail/part-outside-parts-dir | 1 | has | a-pattern bin/lib/test-retire-predicate/case-parser.sh:2
part-outside-c       | fail/part-outside-parts-dir | 1 | has | c-id-compare bin/lib/test-retire-predicate/case-parser.sh:4
part-inside-dir      | fail/part-outside-parts-dir | 1 | lacks | bin/lib/test-language-parts/bash.sh
allow-no-reason      | fail/allowlist-no-reason | 1 | has   | ALLOWLIST no-reason line 1
allow-no-reason-row  | fail/allowlist-no-reason | 1 | lacks | b-location
allow-stale          | fail/allowlist-stale     | 1 | has   | ALLOWLIST stale line 2
allow-stale-used     | fail/allowlist-stale     | 1 | lacks | ALLOWLIST stale line 1
concrete-filenames   | pass/concrete-filenames  | 0 | -     | -
single-pattern       | pass/single-pattern      | 0 | -     | -
comments-excluded    | pass/comments-and-excluded | 0 | -   | -
allowlisted          | pass/allowlisted         | 0 | -     | -
single-name-list     | pass/single-name-list    | 0 | -     | -
single-name-object   | pass/single-name-object  | 0 | -     | -
shell-name-compare   | pass/shell-name-compare  | 0 | -     | -
source-glob-prose    | pass/source-glob         | 0 | -     | -
TABLE
# Every fixture file is a row of the table: none can sit unread.
for fx in "$FXD"/fail/*.fx "$FXD"/pass/*.fx; do
  rel="${fx#"$FXD/"}"
  rel="${rel%.fx}"
  if grep -qxF -- "$rel" "$TMPBASE/rows"; then pass "fixture $rel has a table row"; else fail "fixture $rel has a table row" "not in the table"; fi
done
case_end

case_begin "table-entry-adds-words" "hooks/lib/test-language-registry.json"
D="$TMPBASE/fx/new-entry"
fx_unpack "$FXD/new-entry.fx" "$D"
scan "$D" "$FX_TABLE"
assert_eq "without the entry: rc=$SC_RC" "without the entry: rc=0"
scan "$D" "$TMPBASE/table-plus.json"
assert_eq "with the entry: rc=$SC_RC" "with the entry: rc=1"
for tok in "b-location bin/fake-discovery.sh:1" "c-id-compare bin/fake-discovery.sh:2"; do
  if printf '%s\n' "$SC_OUT" | grep -qF -- "$tok"; then pass "new entry reports [$tok]"; else fail "new entry reports [$tok]" "$SC_OUT"; fi
done
scan "$D" "$TMPBASE/no-such-table.json"
assert_eq "unreadable table: rc=$SC_RC" "unreadable table: rc=2"
case_end

case_begin "repo-has-no-residue" "hooks/lib/test-language-registry.json"
# The real table and allowlist over this checkout: every flagged line is fixed or allowlisted with a reason.
scan "$AGENTS_DIR" "$AGENTS_DIR/hooks/lib/test-language-registry.json" "$RD/allowlist.tsv"
if [ "$SC_RC" = "0" ]; then
  pass "no residue outside the registry ($(printf '%s\n' "$SC_OUT" | tail -n 1))"
else
  fail "no residue outside the registry" "rc=$SC_RC $(printf '%s\n' "$SC_OUT" | head -n 15 | tr '\n' '|')"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
