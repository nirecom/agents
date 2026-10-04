# Reader API (match priority, selfIdentifying, stripName, globs), the CLI's two
# formats, and the Java / Terraform paper check. Sourced by the dispatcher.

echo ""
echo "=== reader and CLI ==="

RD_DIR="$TMPBASE/reader"
mkdir -p "$RD_DIR"
FX_OVERLAP="$TMPBASE/co-overlap"
FX_JT="$TMPBASE/co-java-terraform"
fx_checkout "$FX_OVERLAP" "$FIXTURES/overlap.json"
fx_checkout "$FX_JT" "$FIXTURES/java-terraform.json"

# rd_expect <reader> <command> <label> — stdin rows "name|v1[|v2]"; compares the driver
# output for the names against the rows (| becomes a tab).
rd_expect() {
  local reader="$1" cmd="$2" label="$3"
  tr '|' '\t' >"$RD_DIR/want"
  cut -f1 "$RD_DIR/want" >"$RD_DIR/names"
  drv "$cmd" "$reader" "$RD_DIR/names" >"$RD_DIR/got" 2>&1
  same_text "$label" "$RD_DIR/got" "$RD_DIR/want"
}

case_begin "match-priority-real-table" "hooks/lib/test-language-registry.js"
# supported first, then table order; `*` is one or more characters; case-sensitive.
rd_expect "$READER" match "matchBasename on the real table" <<'ROWS'
a.sh|bash|supported
.x.sh|bash|supported
.sh|-|-
x.Tests.ps1|pester|supported
.Tests.ps1|-|-
test_a.py|pytest|supported
test_.py|test-naming-convention|recognized-only
a.js|js|recognized-only
a.test.js|js|recognized-only
a.spec.js|js|recognized-only
test_a.sh|bash|supported
a_test.sh|bash|supported
test_a.Tests.ps1|pester|supported
a_test.py|test-naming-convention|recognized-only
foo.test.ts|test-naming-convention|recognized-only
a b.sh|bash|supported
README.md|-|-
a.TESTS.ps1|-|-
A.SH|-|-
ROWS
case_end

case_begin "match-priority-overlap-fixture" "hooks/lib/test-language-registry.js"
# rec-a precedes sup-b/sup-c in the table but is recognized-only, so it never wins.
rd_expect "$FX_OVERLAP/hooks/lib/test-language-registry.js" match "matchBasename on overlap.json" <<'ROWS'
xa.ov|sup-b|supported
x.ov|sup-c|supported
za.ov|sup-c|supported
ya.ov|sup-c|supported
qa-c-b|sup-c|supported
yb.sh|bash|supported
yb|rec-d|recognized-only
y|-|-
.ov|-|-
-c-|-|-
q.zz|-|-
ROWS
case_end

case_begin "matches-self-identifying" "hooks/lib/test-language-registry.js"
# Any selfIdentifying entry counts, not only the single resolved one (test_a.sh is bash).
rd_expect "$READER" selfid "matchesSelfIdentifying on the real table" <<'ROWS'
a.spec.js|1
a.test.js|1
test_a.sh|1
a_test.sh|1
foo.Tests.ps1|1
test_a.py|1
a.sh|0
a.js|0
a.py|0
.sh|0
.Tests.ps1|0
ROWS
case_end

case_begin "strip-name" "hooks/lib/test-language-registry.js"
rd_expect "$READER" strip "stripName on the real table" <<'ROWS'
a.sh|a
x.Tests.ps1|x
test_a.py|test_a
a.js|a
a.test.js|a.test
a_test.py|a_test.py
README.md|README.md
ROWS
case_end

case_begin "globs-and-header-lines" "hooks/lib/test-language-registry.js"
assert_eq "$(drv globs "$READER" pester | tr '\n' ' ')" "?*.Tests.ps1 "
assert_eq "$(drv globs "$READER" pytest | tr '\n' ' ')" "test_?*.py "
assert_eq "$(drv globs "$READER" test-naming-convention | tr '\n' ' ')" "?*.test.?* ?*.spec.?* ?*_test.?* test_?* "
assert_eq "headerMaxLines=$(drv hml "$READER")" "headerMaxLines=10"
case_end

case_begin "cli-shell-format" "bin/test-language-registry"
cli --format shell
printf '%s\n' "$CLI_OUT" >"$RD_DIR/cli-shell"
drv dump "$READER" >"$RD_DIR/dump"
same_text "toShellDump() equals the CLI shell output" "$RD_DIR/dump" "$RD_DIR/cli-shell"
T=$'\t'
for want in "schema${T}1" "headerMaxLines${T}10" "tableDrivenFallbackEntry${T}bash" \
  "entry${T}bash${T}supported${T}0" "entry${T}pester${T}supported${T}1" "entry${T}js${T}recognized-only${T}0" \
  "pattern${T}bash${T}*.sh" "glob${T}bash${T}?*.sh" "glob${T}pytest${T}test_?*.py" \
  "field${T}bash${T}caseMarkerReader.function${T}trp_parse_case_markers" \
  "field${T}bash${T}diagnostics.flatRejectCode${T}FLAT_TEST_SH_REJECTED" \
  "field${T}pester${T}launch.requires${T}pwsh" "field${T}pytest${T}launch.requires${T}uv" \
  "field${T}pester${T}launch.timeoutSeconds${T}180" "arg${T}bash${T}command${T}{path}"; do
  has_line "shell line $(printf '%q' "$want")" "$CLI_OUT" "$want"
done
assert_eq "$(printf '%s\n' "$CLI_OUT" | awk -F'\t' '$1=="entry"{printf "%s ", $2}')" "$(json_ids "$TABLE")"
assert_eq "$(printf '%s\n' "$CLI_OUT" | awk -F'\t' '$1=="arg" && $2=="pester" && $3=="command"{printf "[%s]", $4}')" "[pwsh][-NoProfile][-Command][Invoke-Pester -Path '{nativePathSq}' -CI]"
case_end

case_begin "cli-json-format" "bin/test-language-registry"
cat >"$RD_DIR/jsonchk.js" <<'JS'
const t = JSON.parse(require("fs").readFileSync(0, "utf8"));
const bad = t.entries.filter((e) => JSON.stringify(e.globs) !== JSON.stringify(e.patterns.map((p) => p.replace(/\*/g, "?*"))));
console.log(`entries=${t.entries.length} headerMaxLines=${t.headerMaxLines} globsMismatch=${bad.map((e) => e.id).join(",")}`);
JS
cli --format json
got="$(printf '%s' "$CLI_OUT" | node "$(np "$RD_DIR/jsonchk.js")" 2>&1)"
want_n="$(json_ids "$TABLE" | wc -w | tr -d ' ')"
assert_eq "$got" "entries=$want_n headerMaxLines=10 globsMismatch="
case_end

case_begin "reader-ids-follow-table" "bin/test-language-registry"
# Every reader reports the entry set the JSON holds, with no count or id list in the test:
# the real table, and the real table plus one extra valid entry (java-junit from java-terraform.json).
FX_EXTRA="$TMPBASE/co-extra-entry"
node -e '
const fs = require("fs");
const [real, jt, out] = process.argv.slice(1);
const t = JSON.parse(fs.readFileSync(real, "utf8"));
t.entries.push(JSON.parse(fs.readFileSync(jt, "utf8")).entries.find((e) => e.id === "java-junit"));
fs.writeFileSync(out, JSON.stringify(t, null, 1));
' "$(np "$TABLE")" "$(np "$FIXTURES/java-terraform.json")" "$(np "$RD_DIR")/extra-entry.json"
fx_checkout "$FX_EXTRA" "$RD_DIR/extra-entry.json"
assert_eq "extra table adds one entry: $(json_ids "$FX_EXTRA/hooks/lib/test-language-registry.json" | wc -w | tr -d ' ')" \
  "extra table adds one entry: $(($(json_ids "$TABLE" | wc -w) + 1))"
for co in "$AGENTS_DIR" "$FX_EXTRA"; do
  tbl="$co/hooks/lib/test-language-registry.json"; tag="${co##*/}"
  want="$(json_ids "$tbl")"
  got="$(node "$(np "$co/bin/test-language-registry")" --format shell 2>&1 | awk -F'\t' '$1=="entry"{printf "%s ", $2}')"
  assert_eq "$tag CLI shell ids: $got" "$tag CLI shell ids: $want"
  got="$(node "$(np "$co/bin/test-language-registry")" --format json 2>&1 | node -e 'const t=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(t.entries.map((e)=>e.id+" ").join(""))' 2>&1)"
  assert_eq "$tag CLI json ids: $got" "$tag CLI json ids: $want"
  got="$(node -e 'process.stdout.write(require(process.argv[1]).loadRegistry().entries.map((e)=>e.id+" ").join(""))' "$(np "$co/hooks/lib/test-language-registry.js")" 2>&1)"
  assert_eq "$tag Node reader ids: $got" "$tag Node reader ids: $want"
  for st in supported recognized-only; do
    got="$(tlr_bash "$co" 'tlr_load || exit 96; tlr_ids "$1" | tr "\n" " "' "$st")"
    assert_eq "$tag bash tlr_ids $st: $got" "$tag bash tlr_ids $st: $(json_ids "$tbl" "$st")"
  done
done
has_line "extra entry reaches the CLI" "$(node "$(np "$FX_EXTRA/bin/test-language-registry")" --format shell)" "entry${T}java-junit${T}supported${T}1"
case_end

case_begin "java-terraform-paper-check" "bin/test-language-registry"
cli --format shell --file "$(np "$FIXTURES/java-terraform.json")"
assert_eq "java-terraform.json rc=$CLI_RC" "java-terraform.json rc=0"
for want in "entry${T}java-junit${T}supported${T}1" "glob${T}java-junit${T}?*Test.java" \
  "field${T}java-junit${T}launch.unit${T}suite" "field${T}java-junit${T}launch.suiteRootMarker${T}build.gradle" \
  "field${T}java-junit${T}launch.timeoutSeconds${T}600" "field${T}java-junit${T}header.commentPrefix${T}//" \
  "field${T}terraform-test${T}launch.suiteRootMarker${T}.terraform.lock.hcl" \
  "field${T}terraform-test${T}launch.requires${T}terraform"; do
  has_line "java-terraform line $(printf '%q' "$want")" "$CLI_OUT" "$want"
done
assert_eq "$(printf '%s\n' "$CLI_OUT" | awk -F'\t' '$1=="arg" && $2=="terraform-test" && $3=="prepare"{printf "%s ", $4}')" "terraform init -input=false "
assert_eq "$(printf '%s\n' "$CLI_OUT" | awk -F'\t' '$1=="arg" && $2=="terraform-test" && $3=="command"{printf "%s ", $4}')" "terraform test "
rd_expect "$FX_JT/hooks/lib/test-language-registry.js" match "Node match on java-terraform.json" <<'ROWS'
FooTest.java|java-junit|supported
Foo.java|-|-
Test.java|-|-
main.tftest.hcl|terraform-test|supported
.tftest.hcl|-|-
ROWS
got="$(tlr_bash "$FX_JT" 'tlr_load || exit 96; for n in FooTest.java main.tftest.hcl Foo.java; do if tlr_match "$n"; then printf "%s=%s " "$n" "$TLR_ID"; else printf "%s=none " "$n"; fi; done; printf "%s %s" "$(tlr_field java-junit launch.requires)" "$(tlr_field terraform-test launch.suiteRootMarker)"')"
assert_eq "$got" "FooTest.java=java-junit main.tftest.hcl=terraform-test Foo.java=none gradle .terraform.lock.hcl"
case_end
