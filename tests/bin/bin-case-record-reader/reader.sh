# crr_read: the FILE/CASE record format, each marker state, the deps column, the reader
# failure path and parity with trp_marker_conformance. Sourced by the dispatcher.

echo ""
echo "=== crr_read ==="

printf 'not a test\n' >"$FXD/notes.txt"

case_begin "record-format-conforming" "bin/lib/case-record-reader.sh"
# Exact output: FILE line first, then one CASE line per case in file order, idx 0-based.
crr "$AGENTS_DIR" "$FXD/conforming.sh"
assert_eq "rc=$CRR_RC" "rc=0"
want="FILE${T}conforming${T}${T}
CASE${T}0${T}alpha${T}bin/a.sh${T}7${T}10${T}helper_a,helper_b${T}
CASE${T}1${T}beta${T}bin/b.sh${T}11${T}13${T}${T}"
assert_eq "$CRR_OUT" "$want"
# Every CASE line has exactly 8 tab-separated fields (empty ones included).
nf="$(printf '%s\n' "$CRR_OUT" | awk -F'\t' '$1 == "CASE" { print NF }' | sort -u | tr '\n' ' ')"
assert_eq "CASE field counts: $nf" "CASE field counts: 8 "
case_end

case_begin "state-per-file" "bin/lib/case-record-reader.sh"
# name|file|want "state|line|reason" of the FILE line, and how many CASE lines follow.
while IFS='|' read -r cname cfile cstate cline creason ccases; do
  [ -n "$cname" ] || continue
  crr "$AGENTS_DIR" "$FXD/$cfile"
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
recognized-only-js|x.test.js|unsupported|||0
supported-without-reader|x.Tests.ps1|unsupported|||0
unmatched-name|notes.txt|unsupported|||0
heredoc-pseudo-markers|heredoc-pseudo.sh|none|||0
ROWS
case_end

case_begin "state-matches-marker-conformance" "bin/lib/case-record-reader.sh"
# The registry-routed path and the direct parser path decide the state by one rule.
for cf in none.sh conforming.sh malformed.sh uncertain.sh heredoc-pseudo.sh; do
  direct="$(bash -c '. "$1/bin/lib/test-retire-predicate.sh" || exit 95; trp_marker_conformance "$2"; printf "%s|%s|%s" "$TRP_MARKER_STATE" "$TRP_MARKER_LINE" "$TRP_MARKER_REASON"' _ "$AGENTS_DIR" "$FXD/$cf" 2>/dev/null)"
  crr "$AGENTS_DIR" "$FXD/$cf"
  if [ -z "$direct" ]; then
    fail "$cf: trp_marker_conformance produced nothing"
  else
    assert_eq "$cf crr=$(file_line "$CRR_OUT")" "$cf crr=$direct"
  fi
done
case_end

case_begin "deps-csv-and-empty" "bin/lib/case-record-reader.sh"
# Column 7: a csv of top-level functions the case calls; empty when it calls none.
# A name that is only a prefix of a called function, and a variable, are not deps.
crr "$AGENTS_DIR" "$FXD/deps-boundary.sh"
deps="$(printf '%s\n' "$CRR_OUT" | awk -F'\t' '$1 == "CASE" { print $2 "=" $7 }' | tr '\n' ' ')"
assert_eq "$deps" "0=mk_more 1=fn_kw "
crr "$AGENTS_DIR" "$FXD/deps-heredoc.sh"
deps="$(printf '%s\n' "$CRR_OUT" | awk -F'\t' '$1 == "CASE" { print $2 "=" $7 }' | tr '\n' ' ')"
assert_eq "heredoc body is not a reference: $deps" "heredoc body is not a reference: 0=real_fn "
case_end

# Fixture checkouts: the bash entry with no caseEmbedRules, and with an unreachable reader.
CO_NOEMBED="$TMPBASE/co-noembed"
fx_table_edit "$AGENTS_DIR/hooks/lib/test-language-registry.json" "$TMPBASE/noembed.json" \
  't.entries.find((e) => e.id === "bash").caseEmbedRules = null;'
fx_checkout "$CO_NOEMBED" "$TMPBASE/noembed.json"
CO_R70="$TMPBASE/co-reader-missing"
fx_table_edit "$AGENTS_DIR/hooks/lib/test-language-registry.json" "$TMPBASE/reader-missing.json" \
  't.entries.find((e) => e.id === "bash").caseMarkerReader.file = "bin/lib/test-language-parts/no-such-reader.sh";'
fx_checkout "$CO_R70" "$TMPBASE/reader-missing.json"

case_begin "deps-unknown-without-embed-rules" "bin/lib/case-record-reader.sh"
# A language with no caseEmbedRules cannot compute deps: `?`, never a silent empty.
crr "$CO_NOEMBED" "$FXD/conforming.sh"
assert_eq "rc=$CRR_RC FILE=$(file_line "$CRR_OUT")" "rc=0 FILE=conforming||"
deps="$(printf '%s\n' "$CRR_OUT" | awk -F'\t' '$1 == "CASE" { print $2 "=" $7 }' | tr '\n' ' ')"
assert_eq "$deps" "0=? 1=? "
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
crr "$AGENTS_DIR" "$FXD/tab-in-name.sh"
hit="$(printf '%s\n' "$CRR_OUT" | awk -F'\t' '($1 == "FILE" && $4 == "grammar") || ($1 == "CASE" && NF == 8 && $8 == "grammar") { print "hit"; exit }')"
assert_eq "grammar reported: ${hit:-no}" "grammar reported: hit"
bad="$(printf '%s\n' "$CRR_OUT" | awk -F'\t' '$1 == "CASE" && NF != 8 { print NR }' | tr '\n' ' ')"
assert_eq "CASE lines with a field count other than 8: [$bad]" "CASE lines with a field count other than 8: []"
case_end

case_begin "case-globals-left-for-same-shell" "bin/lib/case-record-reader.sh"
# The caseEmbedRules ops read the parser globals crr_read leaves behind.
got="$(run_with_timeout 120 bash -c '. "$1/bin/lib/case-record-reader.sh" || exit 97; crr_read "$2" >/dev/null; printf "%s|%s|%s" "${TRP_CASE_BEGIN_LINES[*]}" "${TRP_CASE_END_LINES[*]}" "${TRP_CASE_NAMES[*]}"' _ "$AGENTS_DIR" "$FXD/conforming.sh" 2>/dev/null)"
assert_eq "$got" "7 11|10 13|alpha beta"
case_end
