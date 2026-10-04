# bash loader (bin/lib/test-language-registry.sh): locations, load cache key, field
# and condition queries, tlr_list_dir order, and the real table's part references.
# Sourced by the dispatcher.

echo ""
echo "=== bash loader ==="

LD_DIR="$TMPBASE/loader"
mkdir -p "$LD_DIR"

case_begin "loader-locations-and-header-lines" "bin/lib/test-language-registry.sh"
got="$(tlr_bash "$AGENTS_DIR" 'tlr_load || exit 96; printf "%s|%s|%s|%s" "$TLR_HEADER_MAX_LINES" "$(cd "$TLR_REPO_ROOT" && pwd -P)" "$(cd "$TLR_REGISTRY_DIR" && pwd -P)" "${_TLR_SELF_CLI##*/}"')"
assert_eq "$got" "10|$(cd "$AGENTS_DIR" && pwd -P)|$(cd "$AGENTS_DIR/hooks/lib" && pwd -P)|test-language-registry"
case_end

case_begin "loader-cache-key" "bin/lib/test-language-registry.sh"
# Another table changes the key and the answers; the same key is not re-read (works without node).
JT_TABLE="$(np "$FIXTURES/java-terraform.json")"
got="$(tlr_bash "$AGENTS_DIR" '
tlr_load || exit 96; k1="$TLR_LOADED_KEY"
tlr_match FooTest.java; r1=$?
tlr_load "$1" || exit 95; k2="$TLR_LOADED_KEY"
tlr_match FooTest.java; r2="$?:$TLR_ID"
tlr_load || exit 94
tlr_match FooTest.java; r3=$?
[ -n "$k1" ] && [ "$k1" != "$k2" ] && kd=differ || kd="same:[$k1]"
printf "%s %s %s %s" "$r1" "$r2" "$r3" "$kd"' "$JT_TABLE")"
assert_eq "$got" "1 0:java-junit 1 differ"
node_dir="$(dirname "$(command -v node)")"
if [ "$node_dir" = "$(dirname "$(command -v bash)")" ]; then
  skip "cached load without node (node shares its directory with bash)"
else
  got="$(tlr_bash "$AGENTS_DIR" 'tlr_load || exit 96; PATH="$1"; tlr_load; s=$?; tlr_load "$2"; printf "same=%s other=%s" "$s" "$?"' "$(path_without node)" "$JT_TABLE")"
  assert_eq "$got" "same=0 other=1"
fi
case_end

case_begin "loader-field-and-stem" "bin/lib/test-language-registry.sh"
got="$(tlr_bash "$AGENTS_DIR" 'tlr_load || exit 96
for q in "bash launch.unit" "pester launch.requires" "pytest launch.requires" "pytest nameStrip.suffix" "bash caseMarkerReader.file" "js tableDrivenDetector.function" "pester caseMarkerReader.file"; do
  printf "[%s]" "$(tlr_field $q)"
done
for n in a.sh x.Tests.ps1 test_a.py a.test.js a_test.py README.md; do printf "<%s>" "$(tlr_stem "$n")"; done')"
assert_eq "$got" "[file][pwsh][uv][.py][bin/lib/test-retire-predicate/case-parser.sh][has_table_driven_js][]<a><x><test_a><a.test><a_test.py><README.md>"
case_end

case_begin "loader-conditions" "bin/lib/test-language-registry.sh"
# Conditions are decided by which fields an entry has, never by its id. The expected
# "patterns|globs" come from the JSON, so a new entry needs no edit here.
cond_oracle() {
  node -e '
const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const sup = (e) => e.status === "supported";
const meets = { supported: sup, "recognized-only": (e) => e.status === "recognized-only",
  "case-marker": (e) => sup(e) && !!e.caseMarkerReader, "table-driven": (e) => !!e.tableDrivenDetector,
  "helper-library": (e) => sup(e) && !!e.helperLibrary }[process.argv[2]];
const p = t.entries.filter(meets).flatMap((e) => e.patterns);
process.stdout.write(p.map((x) => x + " ").join("") + "|" + p.map((x) => x.replace(/\*/g, "?*") + " ").join(""));
' "$(np "$TABLE")" "$1"
}
: >"$LD_DIR/conds"
for cond in supported recognized-only case-marker table-driven helper-library; do
  got="$(tlr_bash "$AGENTS_DIR" 'tlr_load || exit 96; tlr_patterns "$1" | tr "\n" " "; printf "|"; tlr_globs "$1" | tr "\n" " "' "$cond")"
  assert_eq "$cond: $got" "$cond: $(cond_oracle "$cond")"
  printf '%s\n' "$cond=$got" >>"$LD_DIR/conds"
done
# Known members, so the oracle cannot drift together with the loader.
for want in "supported *.sh" "case-marker *.sh" "helper-library *.sh" "table-driven *.sh" "table-driven *.js"; do
  re="^${want% *}=([^|]* )?$(printf '%s' "${want#* }" | sed 's/[.*]/\\&/g') [^|]*\\|"
  if grep -Eq -- "$re" "$LD_DIR/conds"; then pass "condition $want"; else fail "condition $want" "$(tr '\n' ' ' <"$LD_DIR/conds")"; fi
done
if grep -q '^recognized-only=.*\*\.sh ' "$LD_DIR/conds"; then
  fail "recognized-only never lists *.sh" "$(grep '^recognized-only=' "$LD_DIR/conds")"
else
  pass "recognized-only never lists *.sh"
fi
case_end

case_begin "loader-list-dir-order" "bin/lib/test-language-registry.sh"
# Entry order, then name; a name two entries match is listed once; directories never.
mkdir -p "$LD_DIR/sup/dir.sh" "$LD_DIR/rec"
for f in z.sh a.sh b.Tests.ps1 a.Tests.ps1 test_b.py test_a.py x.js README.md .sh; do : >"$LD_DIR/sup/$f"; done
for f in x.js a.test.js foo_test.rb test_q.txt README.md; do : >"$LD_DIR/rec/$f"; done
list_names() { tlr_bash "$AGENTS_DIR" 'tlr_load || exit 96; tlr_list_dir "$1" "$2"' "$1" "$2" | sed 's#.*/##' | tr '\n' ' '; }
assert_eq "supported: $(list_names "$LD_DIR/sup" supported)" "supported: a.sh z.sh a.Tests.ps1 b.Tests.ps1 test_a.py test_b.py "
assert_eq "recognized-only: $(list_names "$LD_DIR/rec" recognized-only)" "recognized-only: a.test.js x.js foo_test.rb test_q.txt "
mkdir -p "$LD_DIR/empty"
got="$(tlr_bash "$AGENTS_DIR" 'tlr_load || exit 96; tlr_list_dir "$1" supported; echo "rc=$?"' "$LD_DIR/empty")"
assert_eq "empty dir: [$got]" "empty dir: [rc=0]"
case_end

case_begin "real-table-part-refs-resolve" "bin/lib/test-language-registry.sh"
# Every part reference in the real table names a repo file that defines the function.
drv parts "$READER" >"$LD_DIR/parts" 2>&1
nparts=0
while IFS=$'\t' read -r pid pfield pfile pfn; do
  [ -n "$pid" ] || continue
  nparts=$((nparts + 1))
  if [ -f "$AGENTS_DIR/$pfile" ] && grep -Eq "^(function[[:space:]]+)?${pfn}[[:space:]]*\(\)" "$AGENTS_DIR/$pfile"; then
    pass "$pid.$pfield -> $pfile defines $pfn"
  else
    fail "$pid.$pfield -> $pfile defines $pfn" "file missing or function not defined"
  fi
done <"$LD_DIR/parts"
if [ "$nparts" -ge 3 ]; then
  pass "real table has $nparts part references"
else
  fail "real table has at least 3 part references" "found $nparts: $(head -n 3 "$LD_DIR/parts" | tr '\n' ' ')"
fi
case_end

case_begin "call-part-real-detector" "bin/lib/test-language-registry.sh"
printf '%s\n' "while IFS='|' read -r a b; do :; done" >"$LD_DIR/td.sh"
printf '%s\n' 'echo plain' >"$LD_DIR/plain.sh"
got="$(tlr_bash "$AGENTS_DIR" 'tlr_load || exit 96; tlr_call_part bash tableDrivenDetector "$1"; a=$?; tlr_call_part bash tableDrivenDetector "$2"; printf "%s %s" "$a" "$?"' "$LD_DIR/td.sh" "$LD_DIR/plain.sh")"
assert_eq "table-driven / plain: $got" "table-driven / plain: 0 1"
case_end
