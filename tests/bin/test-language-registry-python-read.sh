#!/usr/bin/env bash
# tests/bin/test-language-registry-python-read.sh
# Tests: bin/normalize-harness-position.py, bin/test-language-registry
# Tags: TL2, bin, test-language-registry, python, glob, scope:common
# Python reads the registry through `node <CLI> --format json` and rglobs only the
# converted globs. Separate from tests/bin/test-language-registry.sh because the
# whole file needs uv (exit 77 without it).
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

for tool in uv node; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool not available"
    exit 77
  fi
done

TMPBASE="$(make_tmp)"
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
# shellcheck source=test-language-registry/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/test-language-registry/_lib.sh"
cd "$TMPBASE" || exit 1

# nhp <checkout> — the checkout's normalizer in dry-run over all multi-path tests.
nhp() {
  NHP_RC=0
  NHP_OUT="$(run_with_timeout 180 uv run --no-project python "$(np "$1/bin/normalize-harness-position.py")" --all-multi-path --dry-run 2>&1)" || NHP_RC=$?
}

case_begin "python-target-count-matches-bash" "bin/normalize-harness-position.py"
# Expected: tests/**/?*.sh outside _archive whose first `# Tests:` line (first 10 lines) has 2+ paths.
want=0
while IFS= read -r f; do
  if head -n 10 "$f" | awk '/^# Tests:/ { sub(/^# Tests:/, ""); n = split($0, a, ","); print (n >= 2 ? "y" : "n"); exit }' | grep -q y; then
    want=$((want + 1))
  fi
done < <(find "$SCRIPT_CHECKOUT_ROOT/tests" -name '?*.sh' -type f -not -path '*/_archive/*')
nhp "$SCRIPT_CHECKOUT_ROOT"
assert_eq "real repo rc=$NHP_RC" "real repo rc=0"
has_line "real repo target count" "$NHP_OUT" "Found $want multi-path test files"
case_end

case_begin "python-rglob-boundary-equals-node" "bin/test-language-registry"
FX_PY="$TMPBASE/co-python"
fx_checkout "$FX_PY"
mkdir -p "$FX_PY/tests/hooks"
names=(".sh" "a.sh" ".x.sh" "x.Tests.ps1" ".Tests.ps1" "test_.py" "test_a.py" "a b.sh"
  "test_a.sh" "a.test.js" "a.spec.js" "a_test.sh" "test_a.Tests.ps1")
for n in "${names[@]}"; do
  printf '%s\n' '#!/usr/bin/env bash' '# Tests: hooks/lib/x.js, bin/y.sh' >"$FX_PY/tests/hooks/$n"
done
printf '%s\n' "${names[@]}" >"$TMPBASE/names"
# The harness helper library belongs to the bash entry, so Python must list exactly its names.
drv match "$READER" "$TMPBASE/names" | awk -F'\t' '$2=="bash"{print $1}' | sort >"$TMPBASE/want"
nhp "$FX_PY"
assert_eq "fixture rc=$NHP_RC" "fixture rc=0"
printf '%s\n' "$NHP_OUT" | sed -n -E 's#^[A-Z-]+: .*[/\\]tests[/\\]hooks[/\\]##p' | sort >"$TMPBASE/got"
same_text "rglob set equals Node bash set" "$TMPBASE/got" "$TMPBASE/want"
if grep -qxE '\.sh|test_\.py' "$TMPBASE/got"; then
  fail "rglob never lists .sh or test_.py" "$(tr '\n' ' ' <"$TMPBASE/got")"
else
  pass "rglob never lists .sh or test_.py"
fi
case_end

case_begin "python-cli-unreadable-exit-1" "bin/normalize-harness-position.py"
FX_NOCLI="$TMPBASE/co-no-cli"
fx_checkout "$FX_NOCLI"
rm -f "$FX_NOCLI/bin/test-language-registry"
mkdir -p "$FX_NOCLI/tests/hooks"
printf '%s\n' '#!/usr/bin/env bash' '# Tests: hooks/lib/x.js, bin/y.sh' >"$FX_NOCLI/tests/hooks/a.sh"
nhp "$FX_NOCLI"
assert_eq "no CLI rc=$NHP_RC" "no CLI rc=1"
case "$NHP_OUT" in
  *registry*) pass "no CLI: message names the registry" ;;
  *) fail "no CLI: message names the registry" "$NHP_OUT" ;;
esac
case "$NHP_OUT" in
  *"Found "*) fail "no CLI: nothing enumerated" "$NHP_OUT" ;;
  *) pass "no CLI: nothing enumerated" ;;
esac
case_end

case_begin "python-tests-marker-per-file-prefix" "bin/normalize-harness-position.py"
# Each file's `Tests:` marker is its own entry's header.commentPrefix (#2500). slash-lang
# (*.slt, "//") gets a helper library here so it is a candidate; other-prefix lines are decoys.
FX_PFX="$TMPBASE/co-python-prefix"
fx_checkout "$FX_PFX"
fx_table_edit "$FIXTURES/slash-header.json" "$FX_PFX/hooks/lib/test-language-registry.json" \
  't.entries[1].helperLibrary = t.entries[0].helperLibrary;'
mkdir -p "$FX_PFX/tests/hooks"
printf '%s\n' '// Tests: hooks/lib/x.js, bin/y.sh' >"$FX_PFX/tests/hooks/m1.slt"
printf '%s\n' '# Tests: hooks/lib/x.js, bin/y.sh' '// Tests: hooks/lib/x.js' >"$FX_PFX/tests/hooks/m2.slt"
printf '%s\n' '#!/usr/bin/env bash' '# Tests: hooks/lib/x.js, bin/y.sh' >"$FX_PFX/tests/hooks/h1.sh"
printf '%s\n' '#!/usr/bin/env bash' '// Tests: hooks/lib/x.js, bin/y.sh' '# Tests: hooks/lib/x.js' >"$FX_PFX/tests/hooks/h2.sh"
nhp "$FX_PFX"
assert_eq "prefix fixture rc=$NHP_RC" "prefix fixture rc=0"
has_line "only own-prefix multi-path headers count" "$NHP_OUT" "Found 2 multi-path test files"
got="$(printf '%s\n' "$NHP_OUT" | sed -n -E 's#^[A-Z-]+: .*[/\\]tests[/\\]hooks[/\\]##p' | sort | tr '\n' ' ')"
assert_eq "listed=$got" "listed=h1.sh m1.slt "
case_end

case_begin "python-rewrites-bash-tests-only" "bin/normalize-harness-position.py"
# #2411: every supported language has a helper library; the normalizer still lists and
# rewrites bash tests only. h1.sh is the control that the rewrite ran at all.
FX_ALL="$TMPBASE/co-python-all-helpers"
fx_checkout "$FX_ALL"
ALL_HELPERS_JS='const b = t.entries.find((e) => e.id === "bash");'
ALL_HELPERS_JS+=' for (const [id, ext] of [["pester", "ps1"], ["pytest", "py"], ["js", "js"]]) {'
ALL_HELPERS_JS+=' const e = t.entries.find((x) => x.id === id);'
ALL_HELPERS_JS+=' e.helperLibrary = e.helperLibrary || Object.assign({}, b.helperLibrary, { path: "tests/lib/harness." + ext });'
ALL_HELPERS_JS+=' e.caseMarkerReader = e.caseMarkerReader || b.caseMarkerReader; }'
fx_table_edit "$TABLE" "$FX_ALL/hooks/lib/test-language-registry.json" "$ALL_HELPERS_JS"
mkdir -p "$FX_ALL/tests/hooks"
for ext in ps1 py js; do
  [ -f "$FX_ALL/tests/lib/harness.$ext" ] || printf '\n' >"$FX_ALL/tests/lib/harness.$ext"
done
printf '%s\n' '#!/usr/bin/env bash' '# Tests: hooks/lib/x.js, bin/y.sh' 'REPO_ROOT="x"' >"$FX_ALL/tests/hooks/h1.sh"
printf '%s\n' '# Tests: hooks/lib/x.js, bin/y.sh' 'REPO_ROOT="x"' >"$FX_ALL/tests/hooks/n1.Tests.ps1"
printf '%s\n' '# Tests: hooks/lib/x.js, bin/y.sh' 'REPO_ROOT="x"' >"$FX_ALL/tests/hooks/test_n2.py"
printf '%s\n' '// Tests: hooks/lib/x.js, bin/y.sh' 'REPO_ROOT="x"' >"$FX_ALL/tests/hooks/n3.js"
others=(n1.Tests.ps1 test_n2.py n3.js)
before="$(cd "$FX_ALL/tests/hooks" && cksum "${others[@]}")"
nhp "$FX_ALL"
assert_eq "all-helpers fixture rc=$NHP_RC" "all-helpers fixture rc=0"
got="$(printf '%s\n' "$NHP_OUT" | sed -n -E 's#^[A-Z-]+: .*[/\\]tests[/\\]hooks[/\\]##p' | sort | tr '\n' ' ')"
assert_eq "listed=$got" "listed=h1.sh "
NHP_RC=0
NHP_OUT="$(run_with_timeout 180 uv run --no-project python "$(np "$FX_ALL/bin/normalize-harness-position.py")" --all-multi-path --add-harness 2>&1)" || NHP_RC=$?
assert_eq "rewrite rc=$NHP_RC" "rewrite rc=0"
if grep -q 'tests/lib/harness\.sh' "$FX_ALL/tests/hooks/h1.sh"; then
  pass "rewrite: the bash test now loads the helper library"
else
  fail "rewrite: the bash test now loads the helper library" "$NHP_OUT"
fi
assert_eq "other languages after=$(cd "$FX_ALL/tests/hooks" && cksum "${others[@]}")" "other languages after=$before"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
