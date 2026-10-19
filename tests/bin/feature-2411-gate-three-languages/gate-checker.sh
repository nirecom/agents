# bin/check-case-markers.sh on PowerShell, Python and JavaScript tests (#2411).
# Sourced by tests/bin/feature-2411-gate-three-languages.sh. Needs the three entries
# registered with a reader part and a helper library.
# shellcheck shell=bash

echo ""
echo "=== gate: registry and check-case-markers.sh, three languages ==="

REPO_GATE="$TMPBASE/repo-gate"
mkrepo "$REPO_GATE"
GATE_T="$REPO_GATE/tests/bin"
for _lang in "${LANGS[@]}"; do
  for _kind in missing conforming malformed; do
    lang_set "$_lang" "$_kind"
    put "$REPO_GATE" "tests/bin/$LF" "$_lang-$_kind"
  done
done
put "$REPO_GATE" tests/bin/uncertain.js js-uncertain

# one_line <label> <text> <prefix> <suffix> — <text> is exactly one line with both ends.
one_line() {
  case "$2" in
    *$'\n'*) fail "$1" "want one line, got [$2]" ;;
    "$3"*"$4") pass "$1" ;;
    *) fail "$1" "want [$3 ... $4] got [$2]" ;;
  esac
}

case_begin "gate-registry-reader-and-helper-pairs" "hooks/lib/test-language-registry.json"
REG_PAIRS="$(reg_pairs)"
while IFS= read -r _want; do
  [ -n "$_want" ] || continue
  if printf '%s\n' "$REG_PAIRS" | grep -qxF -- "$_want"; then
    pass "registry row $_want"
  else
    fail "registry row" "want [$_want] in [$REG_PAIRS]"
  fi
  IFS='|' read -r _id _rfile _rfn _hpath <<< "$_want"
  if [ -f "$SCRIPT_CHECKOUT_ROOT/$_rfile" ] && [ -f "$SCRIPT_CHECKOUT_ROOT/$_hpath" ]; then
    pass "$_id: reader part and helper library exist"
  else
    fail "$_id: reader part and helper library exist" "missing $_rfile or $_hpath"
  fi
done <<'ROWS'
pester|bin/lib/test-language-parts/pester.sh|pester_case_markers|tests/lib/harness.ps1
pytest|bin/lib/test-language-parts/pytest.sh|pytest_case_markers|tests/lib/harness.py
js|bin/lib/test-language-parts/js.sh|js_case_markers|tests/lib/harness.js
ROWS
case_end

case_begin "gate-checker-missing-blocks-in-own-words" "bin/check-case-markers.sh"
for _lang in "${LANGS[@]}"; do
  lang_set "$_lang" missing
  ck "$GATE_T/$LF"
  assert_eq "$_lang rc=$CK_RC" "$_lang rc=1"
  one_line "$_lang: one HIGH line" "$CK_OUT" "HIGH: $GATE_T/$LF " " code=MISSING_CASE_MARKERS"
  lacks "$_lang wording" "$CK_OUT$CK_ERR" "case_begin"
  lacks "$_lang wording" "$CK_OUT$CK_ERR" "harness.sh"
done
case_end

case_begin "gate-checker-conforming-passes" "bin/check-case-markers.sh"
for _lang in "${LANGS[@]}"; do
  lang_set "$_lang" conforming
  ck "$GATE_T/$LF"
  ck_exact "$_lang: conforming marks print nothing" 0 "" ""
done
case_end

case_begin "gate-checker-malformed-names-the-reason" "bin/check-case-markers.sh"
for _lang in "${LANGS[@]}"; do
  lang_set "$_lang" malformed
  ck "$GATE_T/$LF"
  assert_eq "$_lang rc=$CK_RC" "$_lang rc=1"
  one_line "$_lang: reason $LREASON" "$CK_OUT" "HIGH: $GATE_T/$LF line " "($LREASON) code=MALFORMED_CASE_MARKER"
done
case_end

case_begin "gate-checker-duplicate-name-four-languages" "bin/check-case-markers.sh"
# #2673: a case name used twice is malformed at its second begin line, in every language.
while IFS='|' read -r _lang _file _line; do
  [ -n "$_lang" ] || continue
  put "$REPO_GATE" "tests/bin/$_file" "$_lang-dupname"
  ck "$GATE_T/$_file"
  assert_eq "$_lang dupname: rc=$CK_RC out=$CK_OUT" \
    "$_lang dupname: rc=1 out=HIGH: $GATE_T/$_file line $_line: malformed case marker (duplicate-name) code=MALFORMED_CASE_MARKER"
done <<'ROWS'
sh|dupname.sh|7
pester|dupname.Tests.ps1|9
pytest|test_dupname.py|16
js|dupname.js|7
ROWS
case_end

case_begin "gate-checker-js-uncertain-warns-only" "bin/check-case-markers.sh"
ck "$GATE_T/uncertain.js"
assert_eq "rc=$CK_RC" "rc=0"
one_line "one WARN line" "$CK_OUT" "WARN: $GATE_T/uncertain.js line " " code=UNCERTAIN_CASE_MARKER"
case_end

case_begin "gate-checker-runtime-absent-warns-and-passes" "bin/check-case-markers.sh"
for _lang in pester pytest; do
  lang_set "$_lang" missing
  CK_PATH="$(no_runtime_path "$LREQ")"
  if [ -z "$CK_PATH" ]; then
    fail "$_lang: PATH without $LREQ" "$(cat "$TMPBASE/shim-no-$LREQ.err")"
    continue
  fi
  ck "$GATE_T/$LF"
  CK_PATH=""
  assert_eq "$_lang rc=$CK_RC" "$_lang rc=0"
  _all="$(printf '%s\n%s\n' "$CK_OUT" "$CK_ERR" | grep -v '^$')"
  one_line "$_lang: one WARN line" "$_all" "WARN: " ""
  has "$_lang WARN" "$_all" "$GATE_T/$LF"
  has "$_lang WARN" "$_all" "$LREQ"
  lacks "$_lang WARN" "$_all" "HIGH:"
done
CK_PATH=""
case_end
