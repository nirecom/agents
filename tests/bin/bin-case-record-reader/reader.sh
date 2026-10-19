# crr_read: the FILE/CASE record format, each marker state, the deps column, the reader
# failure path and parity with trp_marker_conformance. Sourced by the dispatcher.

echo ""
echo "=== crr_read ==="

printf 'not a test\n' >"$FXD/notes.txt"

# dup-name.sh (#2673): one case built twice under the same name, so no begin line is written
# literally twice here. Lines: 1 shebang, 2-4 first case, 5-7 second case.
CRR_DUP_BEGIN="case""_begin"  # split so this line is not read as a marker
crr_dup_case() { printf '%s "%s" "%s"\necho %s\ncase_end\n' "$CRR_DUP_BEGIN" "$1" "$2" "$1"; }
printf '#!/usr/bin/env bash\n' >"$FXD/dup-name.sh"
crr_dup_case live bin/a.sh >>"$FXD/dup-name.sh"
crr_dup_case live bin/b.sh >>"$FXD/dup-name.sh"

case_begin "record-format-conforming" "bin/lib/case-record-reader.sh"
# Exact output: FILE line first, then one CASE line per case in file order (no idx column, #2673).
crr "$SCRIPT_CHECKOUT_ROOT" "$FXD/conforming.sh"
assert_eq "rc=$CRR_RC" "rc=0"
want="FILE${T}conforming${T}${T}
CASE${T}alpha${T}bin/a.sh${T}7${T}10${T}helper_a,helper_b${T}
CASE${T}beta${T}bin/b.sh${T}11${T}13${T}${T}"
assert_eq "$CRR_OUT" "$want"
# Every CASE line has exactly 7 tab-separated fields (empty ones included).
nf="$(printf '%s\n' "$CRR_OUT" | awk -F'\t' '$1 == "CASE" { print NF }' | sort -u | tr '\n' ' ')"
assert_eq "CASE field counts: $nf" "CASE field counts: 7 "
case_end

case_begin "state-per-file" "bin/lib/case-record-reader.sh"
# name|file|want "state|line|reason" of the FILE line, and how many CASE lines follow.
while IFS='|' read -r cname cfile cstate cline creason ccases; do
  [ -n "$cname" ] || continue
  crr "$SCRIPT_CHECKOUT_ROOT" "$FXD/$cfile"
  assert_eq "$cname rc=$CRR_RC" "$cname rc=0"
  assert_eq "$cname FILE=$(file_line "$CRR_OUT")" "$cname FILE=$cstate|$cline|$creason"
  n="$(printf '%s\n' "$CRR_OUT" | grep -c "^CASE$T")"
  assert_eq "$cname CASE lines=$n" "$cname CASE lines=$ccases"
  n="$(printf '%s\n' "$CRR_OUT" | grep -c "^FILE$T")"
  assert_eq "$cname FILE lines=$n" "$cname FILE lines=1"
done <<'ROWS'
none|none.sh|none|||0
conforming|conforming.sh|conforming|||2
malformed|malformed.sh|malformed|3|grammar|0
uncertain|uncertain.sh|uncertain|5|depth|0
js-no-markers|x.test.js|none|||0
pester-no-markers|x.Tests.ps1|none|||0
recognized-only-name|x_test.go|unsupported|||0
unmatched-name|notes.txt|unsupported|||0
heredoc-pseudo-markers|heredoc-pseudo.sh|none|||0
ROWS
case_end

case_begin "supported-without-reader-is-unsupported" "bin/lib/case-record-reader.sh"
# java-junit of the fixture table is supported and has no caseMarkerReader; the bash
# row is the control that the same checkout still reads a language that has one.
CO_JT="$TMPBASE/co-java-terraform"
fx_checkout "$CO_JT" "$SCRIPT_CHECKOUT_ROOT/tests/bin/test-language-registry/fixtures/java-terraform.json"
got="$(tlr_bash "$CO_JT" 'tlr_load || exit 96; tlr_match XTest.java; printf "%s/%s" "$TLR_ID" "$TLR_STATUS"')"
assert_eq "XTest.java is $got" "XTest.java is java-junit/supported"
crr "$CO_JT" "$FXD/XTest.java"
assert_eq "rc=$CRR_RC out=$CRR_OUT" "rc=0 out=FILE${T}unsupported${T}${T}"
crr "$CO_JT" "$FXD/conforming.sh"
assert_eq "bash control: rc=$CRR_RC FILE=$(file_line "$CRR_OUT")" "bash control: rc=0 FILE=conforming||"
case_end

case_begin "state-matches-marker-conformance" "bin/lib/case-record-reader.sh"
# The registry-routed path and the direct parser path decide the state by one rule.
for cf in none.sh conforming.sh malformed.sh uncertain.sh heredoc-pseudo.sh dup-name.sh; do
  direct="$(bash -c '. "$1/bin/lib/test-retire-predicate.sh" || exit 95; trp_marker_conformance "$2"; printf "%s|%s|%s" "$TRP_MARKER_STATE" "$TRP_MARKER_LINE" "$TRP_MARKER_REASON"' _ "$SCRIPT_CHECKOUT_ROOT" "$FXD/$cf" 2>/dev/null)"
  crr "$SCRIPT_CHECKOUT_ROOT" "$FXD/$cf"
  if [ -z "$direct" ]; then
    fail "$cf: trp_marker_conformance produced nothing"
  else
    assert_eq "$cf crr=$(file_line "$CRR_OUT")" "$cf crr=$direct"
  fi
done
case_end

case_begin "deps-csv-and-empty" "bin/lib/case-record-reader.sh"
# Column 6: a csv of top-level functions the case calls; empty when it calls none.
# A name that is only a prefix of a called function, and a variable, are not deps.
crr "$SCRIPT_CHECKOUT_ROOT" "$FXD/deps-boundary.sh"
deps="$(printf '%s\n' "$CRR_OUT" | awk -F'\t' '$1 == "CASE" { print $2 "=" $6 }' | tr '\n' ' ')"
assert_eq "$deps" "word-boundary=mk_more function-keyword=fn_kw "
crr "$SCRIPT_CHECKOUT_ROOT" "$FXD/deps-heredoc.sh"
deps="$(printf '%s\n' "$CRR_OUT" | awk -F'\t' '$1 == "CASE" { print $2 "=" $6 }' | tr '\n' ' ')"
assert_eq "heredoc body is not a reference: $deps" "heredoc body is not a reference: a=real_fn "
case_end

# Fixture checkouts: the bash entry with no caseEmbedRules, and with an unreachable reader.
CO_NOEMBED="$TMPBASE/co-noembed"
fx_table_edit "$SCRIPT_CHECKOUT_ROOT/hooks/lib/test-language-registry.json" "$TMPBASE/noembed.json" \
  't.entries.find((e) => e.id === "bash").caseEmbedRules = null;'
fx_checkout "$CO_NOEMBED" "$TMPBASE/noembed.json"
CO_R70="$TMPBASE/co-reader-missing"
fx_table_edit "$SCRIPT_CHECKOUT_ROOT/hooks/lib/test-language-registry.json" "$TMPBASE/reader-missing.json" \
  't.entries.find((e) => e.id === "bash").caseMarkerReader.file = "bin/lib/test-language-parts/no-such-reader.sh";'
fx_checkout "$CO_R70" "$TMPBASE/reader-missing.json"

case_begin "deps-unknown-without-embed-rules" "bin/lib/case-record-reader.sh"
# A language with no caseEmbedRules cannot compute deps: `?`, never a silent empty.
crr "$CO_NOEMBED" "$FXD/conforming.sh"
assert_eq "rc=$CRR_RC FILE=$(file_line "$CRR_OUT")" "rc=0 FILE=conforming||"
deps="$(printf '%s\n' "$CRR_OUT" | awk -F'\t' '$1 == "CASE" { print $2 "=" $6 }' | tr '\n' ' ')"
assert_eq "$deps" "alpha=? beta=? "
case_end

case_begin "reader-unreachable-is-malformed" "bin/lib/case-record-reader.sh"
# tlr_call_part rc 70 is "cannot check": malformed with reason reader, no CASE lines.
crr "$CO_R70" "$FXD/conforming.sh"
assert_eq "rc=$CRR_RC" "rc=0"
st="$(printf '%s\n' "$CRR_OUT" | awk -F'\t' '$1 == "FILE" { print $2 "|" $4 }')"
assert_eq "$st" "malformed|reader"
n="$(printf '%s\n' "$CRR_OUT" | grep -c "^CASE$T")"
assert_eq "CASE lines=$n" "CASE lines=0"
case_end

case_begin "tab-in-value-is-grammar" "bin/lib/case-record-reader.sh"
# A tab inside a name would split the TSV; it must surface as grammar, and no record
# may carry an extra field.
crr "$SCRIPT_CHECKOUT_ROOT" "$FXD/tab-in-name.sh"
hit="$(printf '%s\n' "$CRR_OUT" | awk -F'\t' '($1 == "FILE" && $4 == "grammar") || ($1 == "CASE" && NF == 7 && $7 == "grammar") { print "hit"; exit }')"
assert_eq "grammar reported: ${hit:-no}" "grammar reported: hit"
bad="$(printf '%s\n' "$CRR_OUT" | awk -F'\t' '$1 == "CASE" && NF != 7 { print NR }' | tr '\n' ' ')"
assert_eq "CASE lines with a field count other than 7: [$bad]" "CASE lines with a field count other than 7: []"
case_end

case_begin "case-globals-left-for-same-shell" "bin/lib/case-record-reader.sh"
# The caseEmbedRules ops read the parser globals crr_read leaves behind.
got="$(run_with_timeout 120 bash -c '. "$1/bin/lib/case-record-reader.sh" || exit 97; crr_read "$2" >/dev/null; printf "%s|%s|%s" "${TRP_CASE_BEGIN_LINES[*]}" "${TRP_CASE_END_LINES[*]}" "${TRP_CASE_NAMES[*]}"' _ "$SCRIPT_CHECKOUT_ROOT" "$FXD/conforming.sh" 2>/dev/null)"
assert_eq "$got" "7 11|10 13|alpha beta"
case_end

# Fixture checkout (#2411): the pester entry names a stub reader part that fills the parser
# globals with one stale case and returns $CRR_STUB_RC.
CO_STUB="$TMPBASE/co-stub-reader"
fx_table_edit "$SCRIPT_CHECKOUT_ROOT/hooks/lib/test-language-registry.json" "$TMPBASE/stub-reader.json" \
  't.entries.find((e) => e.id === "pester").caseMarkerReader = { file: "bin/lib/test-language-parts/stub-reader.sh", function: "stub_case_markers" };'
fx_checkout "$CO_STUB" "$TMPBASE/stub-reader.json"
cat >"$CO_STUB/bin/lib/test-language-parts/stub-reader.sh" <<'STUB'
stub_case_markers() {
  TRP_CASE_BEGIN_LINES=(3); TRP_CASE_END_LINES=(9); TRP_CASE_NAMES=(stale); TRP_CASE_TARGETS=(bin/stale.sh)
  TRP_CASE_COUNT=1; TRP_HAS_MARKERS=1; _TRP_MARKER_MALFORMED=0; _TRP_MARKER_UNCERTAIN=0
  return "${CRR_STUB_RC:-0}"
}
STUB
STUB_REQUIRES="$(tlr_bash "$CO_STUB" 'tlr_load || exit 96; tlr_field pester launch.requires')"

case_begin "stub-reader-part-is-called" "bin/lib/case-record-reader.sh"
# Guards the cases below: the stub part is reached, so a non-zero return is what they observe.
export CRR_STUB_RC=0
crr "$CO_STUB" "$FXD/x.Tests.ps1"
assert_eq "rc=$CRR_RC out=$CRR_OUT" "rc=0 out=FILE${T}conforming${T}${T}
CASE${T}stale${T}bin/stale.sh${T}3${T}9${T}?${T}"
assert_eq "requires=$STUB_REQUIRES" "requires=pwsh"
unset CRR_STUB_RC
case_end

case_begin "reader-rc-79-is-unavailable" "bin/lib/case-record-reader.sh"
# 79 is "the runtime is not there": its own state, the fourth field naming the entry's command.
export CRR_STUB_RC=79
crr "$CO_STUB" "$FXD/x.Tests.ps1"
assert_eq "rc=$CRR_RC out=$CRR_OUT" "rc=0 out=FILE${T}unavailable${T}${T}$STUB_REQUIRES"
unset CRR_STUB_RC
case_end

case_begin "reader-rc-other-than-79-is-malformed-reader" "bin/lib/case-record-reader.sh"
for stub_rc in 70 1 3 78 80 124; do
  export CRR_STUB_RC="$stub_rc"
  crr "$CO_STUB" "$FXD/x.Tests.ps1"
  assert_eq "stub rc=$stub_rc: rc=$CRR_RC out=$CRR_OUT" "stub rc=$stub_rc: rc=0 out=FILE${T}malformed${T}${T}reader"
done
unset CRR_STUB_RC
case_end

case_begin "reader-failure-resets-case-globals" "bin/lib/case-record-reader.sh"
# No stale case may survive a reader that did not finish, whichever way it failed.
for stub_rc in 79 70 3; do
  export CRR_STUB_RC="$stub_rc"
  got="$(run_with_timeout 120 bash -c '. "$1/bin/lib/case-record-reader.sh" || exit 97; crr_read "$2" >/dev/null; printf "%s|%s|%s|%s|%s" "${#TRP_CASE_BEGIN_LINES[@]}" "${#TRP_CASE_END_LINES[@]}" "${#TRP_CASE_NAMES[@]}" "${#TRP_CASE_TARGETS[@]}" "$TRP_CASE_COUNT"' _ "$CO_STUB" "$FXD/x.Tests.ps1" 2>/dev/null)"
  assert_eq "stub rc=$stub_rc: $got" "stub rc=$stub_rc: 0|0|0|0|0"
done
unset CRR_STUB_RC
case_end

case_begin "bash-output-bytes-unchanged" "bin/lib/case-record-reader.sh"
# The bash path must not move when other languages gain a reader: every byte, the final newline included.
while IFS='|' read -r cfile cwant; do
  [ -n "$cfile" ] || continue
  run_with_timeout 120 bash -c '. "$1/bin/lib/case-record-reader.sh" || exit 97; crr_read "$2"' _ "$SCRIPT_CHECKOUT_ROOT" "$FXD/$cfile" >"$TMPBASE/bytes.got" 2>"$TMPBASE/bytes.err"
  printf '%b' "$cwant" >"$TMPBASE/bytes.want"
  same_text "$cfile stdout bytes" "$TMPBASE/bytes.got" "$TMPBASE/bytes.want"
  assert_eq "$cfile stderr bytes=$(wc -c <"$TMPBASE/bytes.err" | tr -d ' ')" "$cfile stderr bytes=0"
done <<'ROWS'
none.sh|FILE\tnone\t\t\n
conforming.sh|FILE\tconforming\t\t\nCASE\talpha\tbin/a.sh\t7\t10\thelper_a,helper_b\t\nCASE\tbeta\tbin/b.sh\t11\t13\t\t\n
malformed.sh|FILE\tmalformed\t3\tgrammar\n
uncertain.sh|FILE\tuncertain\t5\tdepth\n
heredoc-pseudo.sh|FILE\tnone\t\t\n
dup-name.sh|FILE\tmalformed\t5\tduplicate-name\n
ROWS
case_end

case_begin "duplicate-name-is-malformed" "bin/lib/case-record-reader.sh"
# The shared state rule rejects a repeated case name at its second begin line, with no CASE line.
crr "$SCRIPT_CHECKOUT_ROOT" "$FXD/dup-name.sh"
assert_eq "rc=$CRR_RC out=$CRR_OUT" "rc=0 out=FILE${T}malformed${T}5${T}duplicate-name"
case_end
