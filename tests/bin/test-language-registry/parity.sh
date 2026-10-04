# Node matchBasename vs bash tlr_match over three name sets, and the glob boundary:
# every tool fed the converted globs must list exactly the Node-supported set.
# Sourced by the dispatcher (after reader.sh, which builds FX_OVERLAP and FX_JT).

echo ""
echo "=== parity and glob boundary ==="

PT_DIR="$TMPBASE/parity"
mkdir -p "$PT_DIR"
BOUNDARY_NAMES=(".sh" "a.sh" ".x.sh" "x.Tests.ps1" ".Tests.ps1" "test_.py" "test_a.py" "a b.sh"
  "test_a.sh" "a.test.js" "a.spec.js" "a_test.sh" "test_a.Tests.ps1")

# Bash side of the parity: "<line>\t<id>\t<status>" for each line of the list in $1.
PT_BASH_MATCH='tlr_load || exit 96
while IFS= read -r l; do
  [ -n "$l" ] || continue
  if tlr_match "${l##*/}"; then printf "%s\t%s\t%s\n" "$l" "$TLR_ID" "$TLR_STATUS"; else printf "%s\t-\t-\n" "$l"; fi
done <"$1"'

# pt_parity <label> <checkout> <list-file>
pt_parity() {
  drv match "$2/hooks/lib/test-language-registry.js" "$3" >"$PT_DIR/node.out" 2>&1
  tlr_bash "$2" "$PT_BASH_MATCH" "$3" >"$PT_DIR/bash.out"
  same_text "$1: bash tlr_match equals Node matchBasename" "$PT_DIR/bash.out" "$PT_DIR/node.out"
}

case_begin "parity-real-table-repo-tests" "bin/lib/test-language-registry.sh"
git -C "$AGENTS_DIR" ls-files tests >"$PT_DIR/repo-list"
if [ "$(grep -c . "$PT_DIR/repo-list")" -gt 100 ]; then
  pass "git ls-files tests lists $(grep -c . "$PT_DIR/repo-list") paths"
else
  fail "git ls-files tests lists the repo's tests" "only $(grep -c . "$PT_DIR/repo-list") paths"
fi
pt_parity "real table x git ls-files tests" "$AGENTS_DIR" "$PT_DIR/repo-list"
case_end

case_begin "parity-real-table-boundary-names" "bin/lib/test-language-registry.sh"
printf '%s\n' "${BOUNDARY_NAMES[@]}" >"$PT_DIR/boundary-list"
pt_parity "real table x boundary names" "$AGENTS_DIR" "$PT_DIR/boundary-list"
case_end

case_begin "parity-fixture-tables" "bin/lib/test-language-registry.sh"
printf '%s\n' FooTest.java Foo.java Test.java main.tftest.hcl .tftest.hcl a.sh xa.ov x.ov za.ov \
  ya.ov qa-c-b yb yb.sh y .ov -c- q.zz "${BOUNDARY_NAMES[@]}" >"$PT_DIR/fixture-list"
pt_parity "java-terraform.json x names" "$FX_JT" "$PT_DIR/fixture-list"
pt_parity "overlap.json x names" "$FX_OVERLAP" "$PT_DIR/fixture-list"
# Control: the two fixture tables really answer differently for the same list.
drv match "$FX_JT/hooks/lib/test-language-registry.js" "$PT_DIR/fixture-list" >"$PT_DIR/jt.out" 2>&1
drv match "$FX_OVERLAP/hooks/lib/test-language-registry.js" "$PT_DIR/fixture-list" >"$PT_DIR/ov.out" 2>&1
if cmp -s "$PT_DIR/jt.out" "$PT_DIR/ov.out"; then
  fail "fixture tables answer differently" "identical match output"
else
  pass "fixture tables answer differently"
fi
case_end

case_begin "glob-boundary-tools-equal-node" "bin/lib/test-language-registry.sh"
GB="$TMPBASE/glob-repo"
mkdir -p "$GB/tests/hooks"
harness_git_init "$GB"
for n in "${BOUNDARY_NAMES[@]}"; do printf 'x\n' >"$GB/tests/hooks/$n"; done
git -C "$GB" add -A
drv match "$READER" "$PT_DIR/boundary-list" | awk -F'\t' '$3=="supported"{print $1}' | sort >"$PT_DIR/want"
if [ "$(grep -c . "$PT_DIR/want")" -ge 6 ]; then
  pass "Node supported set has $(grep -c . "$PT_DIR/want") boundary names"
else
  fail "Node supported set has the boundary names" "$(tr '\n' ' ' <"$PT_DIR/want")"
fi
tlr_bash "$AGENTS_DIR" 'tlr_load || exit 96; tlr_globs supported' >"$PT_DIR/globs"
mapfile -t GB_GLOBS <"$PT_DIR/globs"
inc=() ps=()
for g in "${GB_GLOBS[@]}"; do inc+=("--include=$g"); ps+=(":(glob)tests/hooks/$g"); done
tlr_bash "$AGENTS_DIR" 'tlr_load || exit 96; tlr_list_dir "$1" supported' "$GB/tests/hooks" | sed 's#.*/##' | sort -u >"$PT_DIR/got-list-dir"
tlr_bash "$AGENTS_DIR" 'tlr_load || exit 96; tlr_find "$1" supported' "$GB/tests" | sed 's#.*/##' | sort -u >"$PT_DIR/got-find"
grep -rl -e x "${inc[@]}" "$GB/tests" | sed 's#.*/##' | sort -u >"$PT_DIR/got-grep"
git -C "$GB" ls-files -- "${ps[@]}" | sed 's#.*/##' | sort -u >"$PT_DIR/got-git"
for tool in list-dir find grep git; do
  same_text "glob boundary: $tool equals Node" "$PT_DIR/got-$tool" "$PT_DIR/want"
  if grep -qxE '\.sh|test_\.py' "$PT_DIR/got-$tool"; then
    fail "glob boundary: $tool never lists .sh or test_.py" "$(tr '\n' ' ' <"$PT_DIR/got-$tool")"
  else
    pass "glob boundary: $tool never lists .sh or test_.py"
  fi
done
case_end
