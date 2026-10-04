# Part invocation: a fixture language registers stub parts (fixtures/fake-part.sh);
# the shared code must call them through tlr_call_part, and a missing part is rc 70
# ("cannot check"), never a silent "no markers". Sourced by the dispatcher.

echo ""
echo "=== parts ==="

FX_PART="$TMPBASE/co-fake-part"
fx_checkout "$FX_PART" "$FIXTURES/fake-part.json"
mkdir -p "$FX_PART/bin/lib/test-language-parts" "$FX_PART/tests/hooks"
cp "$FIXTURES/fake-part.sh" "$FX_PART/bin/lib/test-language-parts/fake-part.sh"

# pt_write <file> <body-line> — a test file whose header names a parser target.
pt_write() {
  printf '%s\n' '#!/usr/bin/env bash' '# Tests: hooks/lib/command-parser.js' '# Tags: hooks, scope:common' "$2" >"$1"
}
PT_TESTS="$FX_PART/tests/hooks"
pt_write "$PT_TESTS/a.fakepart" '# FAKE_TABLE'
pt_write "$PT_TESTS/b.fakepart" 'echo none'
pt_write "$PT_TESTS/c.sh" '# FAKE_TABLE'
pt_write "$PT_TESTS/d.zzz" "while IFS='|' read -r a b; do :; done"
pt_write "$PT_TESTS/e.zzz" 'echo none'

# ctd <checkout> <file> — bin/check-table-driven.sh of that checkout; sets CTD_RC / CTD_OUT.
ctd() {
  CTD_RC=0
  CTD_OUT="$(run_with_timeout 180 bash "$1/bin/check-table-driven.sh" "$2" 2>&1)" || CTD_RC=$?
}

case_begin "call-part-fake-reader" "bin/lib/test-language-registry.sh"
got="$(tlr_bash "$FX_PART" 'tlr_load || exit 96; tlr_call_part fake-part caseMarkerReader "$1"; printf "rc=%s arg=%s count=%s" "$?" "$FAKE_READER_ARG" "$TRP_CASE_COUNT"' "$PT_TESTS/a.fakepart")"
assert_eq "$got" "rc=0 arg=$PT_TESTS/a.fakepart count=1"
case_end

case_begin "enumerate-cases-uses-fake-reader" "bin/lib/test-retire-predicate/case-parser.sh"
got="$(tlr_bash "$FX_PART" '. "$1/bin/lib/test-retire-predicate.sh" || exit 95
trp_enumerate_cases "$1" tests/hooks/a.fakepart
printf "markers=%s names=%s alive=%s refcount=%s malformed=%s" "$TRP_HAS_MARKERS" "${TRP_CASE_NAMES[*]}" "${TRP_CASE_ALIVE[*]}" "$TRP_REFCOUNT" "$_TRP_MARKER_MALFORMED"' "$FX_PART")"
assert_eq "$got" "markers=1 names=fake-case alive=1 refcount=1 malformed=0"
case_end

case_begin "check-table-driven-uses-fake-detector" "bin/check-table-driven.sh"
# name|expected rc — .fakepart follows the stub; .sh keeps the bash detector; an
# unmatched name falls back to tableDrivenFallbackEntry (bash).
while IFS='|' read -r tname want; do
  [ -n "$tname" ] || continue
  ctd "$FX_PART" "$PT_TESTS/$tname"
  assert_eq "$tname rc=$CTD_RC" "$tname rc=$want"
  if [ "$want" = "1" ]; then
    case "$CTD_OUT" in
      *MISSING*) pass "$tname reports MISSING" ;;
      *) fail "$tname reports MISSING" "$CTD_OUT" ;;
    esac
  fi
done <<'ROWS'
a.fakepart|0
b.fakepart|1
c.sh|1
d.zzz|0
e.zzz|1
ROWS
case_end

FX_PART_MISSING="$TMPBASE/co-fake-part-missing"
fx_table_edit "$FIXTURES/fake-part.json" "$TMPBASE/fake-part-missing.json" \
  't.entries[1].caseMarkerReader.file = "bin/lib/test-language-parts/no-such-part.sh"; t.entries[1].tableDrivenDetector.function = "fake_no_such_function";'
fx_checkout "$FX_PART_MISSING" "$TMPBASE/fake-part-missing.json"
mkdir -p "$FX_PART_MISSING/bin/lib/test-language-parts" "$FX_PART_MISSING/tests/hooks"
cp "$FIXTURES/fake-part.sh" "$FX_PART_MISSING/bin/lib/test-language-parts/fake-part.sh"
pt_write "$FX_PART_MISSING/tests/hooks/a.fakepart" '# FAKE_TABLE'

case_begin "call-part-missing-is-70" "bin/lib/test-language-registry.sh"
# Missing file (reader) and missing function (detector) are both rc 70.
got="$(tlr_bash "$FX_PART_MISSING" 'tlr_load || exit 96; tlr_call_part fake-part caseMarkerReader "$1"; a=$?; tlr_call_part fake-part tableDrivenDetector "$1"; printf "%s %s" "$a" "$?"' "$FX_PART_MISSING/tests/hooks/a.fakepart")"
assert_eq "missing file / missing function: $got" "missing file / missing function: 70 70"
case_end

case_begin "enumerate-cases-reader-missing" "bin/lib/test-retire-predicate/case-parser.sh"
got="$(tlr_bash "$FX_PART_MISSING" '. "$1/bin/lib/test-retire-predicate.sh" || exit 95
trp_enumerate_cases "$1" tests/hooks/a.fakepart
printf "malformed=%s reason=%s" "$_TRP_MARKER_MALFORMED" "$_TRP_MARKER_MALFORMED_REASON"' "$FX_PART_MISSING")"
assert_eq "$got" "malformed=1 reason=reader"
case_end

case_begin "check-table-driven-part-missing-exit-2" "bin/check-table-driven.sh"
ctd "$FX_PART_MISSING" "$FX_PART_MISSING/tests/hooks/a.fakepart"
assert_eq "missing detector rc=$CTD_RC" "missing detector rc=2"
case_end
