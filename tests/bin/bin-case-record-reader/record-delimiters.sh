# tests/bin/bin-case-record-reader/record-delimiters.sh
# Tests: bin/lib/case-record-reader.sh
# Tags: TL2, bin, case-markers, test-language-registry, scope:issue-specific
# crr_read (#2712): the record delimiters TAB / CR as grammar through the shared state rule, and
# the optional <match-path> that picks the registry row. Sourced by the dispatcher.

echo ""
echo "=== crr_read: record delimiters and <match-path> ==="

CRR_RD_BEGIN="case""_begin"  # split so the fixture lines below are not read as markers
CRR_RD_END="case""_end"
# crr_rd_file <file> <name> — a one-case bash file whose case name is <name> (begin on line 2).
crr_rd_file() {
  printf '%s\n' '#!/usr/bin/env bash' "$CRR_RD_BEGIN \"$2\" \"bin/a.sh\"" 'echo a' "$CRR_RD_END" >"$1"
}
crr_rd_file "$FXD/rd-tab-name.sh" "a${T}b"
crr_rd_file "$FXD/rd-cr-name.sh" "a"$'\r'"b"

# crr_match <checkout> <file> <match-path> — crr_read with the match-path argument; sets CRR_RC / CRR_OUT.
crr_match() {
  CRR_RC=0
  CRR_OUT="$(run_with_timeout 120 bash -c '. "$1/bin/lib/case-record-reader.sh" || exit 97; crr_read "$2" "$3"' _ "$1" "$2" "$3" 2>"$TMPBASE/crr.err")" || CRR_RC=$?
}

case_begin "delimiter-in-name-is-exactly-grammar" "bin/lib/case-record-reader.sh"
# The TAB row keeps today's output once the check moves to the shared state rule; CR is new.
crr "$SCRIPT_CHECKOUT_ROOT" "$FXD/rd-tab-name.sh"
assert_eq "TAB: rc=$CRR_RC out=$CRR_OUT" "TAB: rc=0 out=FILE${T}malformed${T}2${T}grammar"
crr "$SCRIPT_CHECKOUT_ROOT" "$FXD/rd-cr-name.sh"
assert_eq "CR: rc=$CRR_RC out=$CRR_OUT" "CR: rc=0 out=FILE${T}malformed${T}2${T}grammar"
case_end

case_begin "match-path-chooses-the-registry-row" "bin/lib/case-record-reader.sh"
# A copy whose own name matches no language reads as bash when <match-path> names a bash test,
# and gives the same output as the original; the reader still reads the copy's content.
cp "$FXD/conforming.sh" "$FXD/copy.txt"
crr "$SCRIPT_CHECKOUT_ROOT" "$FXD/conforming.sh"
orig="$CRR_OUT"
crr_match "$SCRIPT_CHECKOUT_ROOT" "$FXD/copy.txt" tests/bin/x.sh
assert_eq "copy.txt as tests/bin/x.sh: rc=$CRR_RC same=$([ "$CRR_OUT" = "$orig" ] && echo yes || printf '%q' "$CRR_OUT")" \
  "copy.txt as tests/bin/x.sh: rc=0 same=yes"
# The match-path wins in the other direction too: a .sh file matched as notes.txt is unsupported.
crr_match "$SCRIPT_CHECKOUT_ROOT" "$FXD/conforming.sh" notes.txt
assert_eq "conforming.sh as notes.txt: rc=$CRR_RC out=$CRR_OUT" "conforming.sh as notes.txt: rc=0 out=FILE${T}unsupported${T}${T}"
case_end

case_begin "match-path-omitted-uses-the-file" "bin/lib/case-record-reader.sh"
# Control: without <match-path> the copy's own name decides, so copy.txt is unsupported.
crr "$SCRIPT_CHECKOUT_ROOT" "$FXD/copy.txt"
assert_eq "copy.txt alone: rc=$CRR_RC out=$CRR_OUT" "copy.txt alone: rc=0 out=FILE${T}unsupported${T}${T}"
case_end
