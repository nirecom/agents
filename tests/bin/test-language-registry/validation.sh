# Table validation, CLI exit codes and the hook-side tryLoadRegistry contract.
# Sourced by tests/bin/test-language-registry.sh; shares its helpers.

echo ""
echo "=== validation ==="

VAL_DIR="$TMPBASE/validation"
mkdir -p "$VAL_DIR"
VAL_BASE="$FIXTURES/fake-suite.json"

case_begin "validation-rejects-invalid-tables" "bin/test-language-registry"
# Control: the unmodified base table is valid, so every reject below is caused by its edit.
cli --format shell --file "$(np "$VAL_BASE")"
assert_eq "$CLI_RC" "0"
# name|edit applied to the parsed table t (entries[0] = bash, entries[1] = fake-suite)
while IFS='|' read -r vname vbody; do
  [ -n "$vname" ] || continue
  fx_table_edit "$VAL_BASE" "$VAL_DIR/$vname.json" "$vbody"
  cli --format shell --file "$(np "$VAL_DIR/$vname.json")"
  if [ "$CLI_RC" = "1" ]; then
    pass "CLI rejects $vname with exit 1"
  else
    fail "CLI rejects $vname with exit 1" "rc=$CLI_RC out=$(printf '%s' "$CLI_OUT" | head -n 2)"
  fi
  got="$(drv load "$READER" "$VAL_DIR/$vname.json")"
  assert_eq "$vname loadRegistry=$got" "$vname loadRegistry=THROW"
done <<'ROWS'
bad-status|t.entries[0].status = "maybe";
bad-id-shape|t.entries[0].id = "Bash";
pattern-bracket|t.entries[0].patterns = ["[ab].sh"];
pattern-three-stars|t.entries[0].patterns = ["*a*b*"];
pattern-adjacent-stars|t.entries[0].patterns = ["**.sh"];
pattern-with-slash|t.entries[0].patterns = ["dir/*.sh"];
pattern-question-mark|t.entries[0].patterns = ["?.sh"];
patterns-empty|t.entries[0].patterns = [];
duplicate-id|t.entries.push(JSON.parse(JSON.stringify(t.entries[0])));
flat-reject-code-no-test-prefix|t.entries[0].diagnostics.flatRejectCode = "FLAT_SH_REJECTED";
flat-reject-code-lowercase|t.entries[0].diagnostics.flatRejectCode = "FLAT_TEST_sh_REJECTED";
flat-reject-code-bad-suffix|t.entries[0].diagnostics.flatRejectCode = "FLAT_TEST_SH_DENIED";
part-ref-absolute-file|t.entries[0].caseMarkerReader.file = "/abs/case-parser.sh";
part-ref-bad-function|t.entries[0].tableDrivenDetector.function = "has table driven";
part-ref-missing-function|delete t.entries[0].caseMarkerReader.function;
suite-without-root-marker|delete t.entries[1].launch.suiteRootMarker;
suite-command-uses-path|t.entries[1].launch.command = ["bash", "{path}"];
suite-command-uses-native-path|t.entries[1].launch.command = ["run", "{nativePath}"];
suite-command-uses-native-path-sq|t.entries[1].launch.command = ["run", "'{nativePathSq}'"];
fallback-entry-nonexistent|t.tableDrivenFallbackEntry = "no-such-entry";
ROWS
case_end

case_begin "cli-exit-codes" "bin/test-language-registry"
cli --format shell
assert_eq "shell rc=$CLI_RC" "shell rc=0"
cli --format json
assert_eq "json rc=$CLI_RC" "json rc=0"
# argument errors are 2, never the invalid-table 1
while IFS='|' read -r aname a1 a2; do
  [ -n "$aname" ] || continue
  if [ -n "$a2" ]; then cli "$a1" "$a2"; else cli "$a1"; fi
  assert_eq "$aname rc=$CLI_RC" "$aname rc=2"
done <<'ROWS'
unknown-format|--format|xml
unknown-flag|--bogus|
file-without-value|--file|
ROWS
printf '{ "schema": 1, "entries": [' >"$VAL_DIR/corrupt.json"
cli --format shell --file "$(np "$VAL_DIR/corrupt.json")"
assert_eq "corrupt-json rc=$CLI_RC" "corrupt-json rc=1"
case_end

case_begin "try-load-registry-corrupt" "hooks/lib/test-language-registry.js"
# A reader copy with its default table beside it: valid (control), then corrupt.
TRY_LIB="$VAL_DIR/try/hooks/lib"
install_test_language_registry "$VAL_DIR/try" "$AGENTS_DIR"
got="$(drv tryload "$TRY_LIB/test-language-registry.js" 2>"$VAL_DIR/try.err")"
assert_eq "valid table: tryLoadRegistry=$got" "valid table: tryLoadRegistry=OBJECT"
printf '{ "schema": 1, "entries": [' >"$TRY_LIB/test-language-registry.json"
got="$(drv tryload "$TRY_LIB/test-language-registry.js" 2>"$VAL_DIR/try.err")"
assert_eq "corrupt table: tryLoadRegistry=$got" "corrupt table: tryLoadRegistry=NULL"
assert_eq "corrupt table stderr lines=$(grep -c . "$VAL_DIR/try.err")" "corrupt table stderr lines=1"
got="$(drv load "$TRY_LIB/test-language-registry.js")"
assert_eq "corrupt table: loadRegistry=$got" "corrupt table: loadRegistry=THROW"
case_end
