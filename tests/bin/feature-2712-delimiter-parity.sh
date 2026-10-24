#!/usr/bin/env bash
# tests/bin/feature-2712-delimiter-parity.sh
# Tests: bin/lib/test-retire-predicate/case-state-rules.sh, bin/lib/test-retire-predicate/case-parser.sh, bin/lib/test-language-parts/pester-case-reader.ps1, bin/lib/test-language-parts/pytest-case-reader.py, bin/lib/test-language-parts/js-case-reader.js
# Tags: TL2, bin, case-markers, test-language-registry, scope:issue-specific, test-lang-exception:symmetry
# #2712: a TAB, CR or LF in a case name or a constant value gives `FILE malformed <begin line> grammar`
# from every test case reader, read through crr_read (runtime ones run as child processes of the test case reader).
# TL3 gap: a missing runtime (pwsh / uv) skips its table; CI hosts with all three run it.
set -u

# Rows per language; pytest has value rows only because its names are identifiers:
#   language | name TAB | name CR | name LF | value TAB | value CR | value LF
#   bash     |   yes    |   yes   |   --    |    yes    |   yes    |    --     a marker is one line of "..." text
#   pester   |   yes    |   yes   |   yes   |    yes    |   yes    |   yes     "`t" "`r" "`n" escapes
#   pytest   |   --     |   --    |   --    |    yes    |   yes    |   yes     names are identifiers
#   js       |   yes    |   yes   |   yes   |    yes    |   yes    |   yes     LF through a multi-line template
# Accept rows: line-ending CRs and a written backslash-t are not delimiters.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
export HOME="$TMPBASE/home"
mkdir -p "$HOME"
export NO_LOG=true

T=$'\t' CR=$'\r' BT='`'
# The bash marker words, split so the sample lines below are not markers of this file.
CB="case_""begin" CE="case_""end"
H='#!/usr/bin/env bash'
P=t.Tests.ps1 Y=test_t.py J=t.js
N=0

# dl_read <file> — crr_read's whole output for <file>, run in a fresh shell; sets DL_OUT.
dl_read() {
  DL_OUT="$(run_with_timeout 120 bash -c '. "$1/bin/lib/case-record-reader.sh" || exit 97; crr_read "$2"' _ "$SCRIPT_CHECKOUT_ROOT" "$1" 2>"$TMPBASE/crr.err")"
}

# dl_run <label> <file-name> <want> <line>... — writes the lines (LF-ended) to a fresh file and
# checks crr_read's whole output: `grammar@<n>` means exactly `FILE malformed <n> grammar`.
dl_run() {
  local label="$1" name="$2" want="$3" dir
  shift 3
  N=$((N + 1))
  dir="$TMPBASE/s$N"
  mkdir -p "$dir"
  printf '%s\n' "$@" >"$dir/$name"
  dl_read "$dir/$name"
  case "$want" in
    grammar@*) want="FILE${T}malformed${T}${want#grammar@}${T}grammar" ;;
  esac
  assert_eq "$label: $DL_OUT" "$label: $want"
}

# need <command> — false (with one SKIP) when the runtime of a table is absent.
need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  skip "$1 not available: rows skipped"
  return 1
}

case_begin "bash-delimiters-are-grammar" "bin/lib/test-retire-predicate/case-state-rules.sh"
dl_run "bash name TAB" t.sh grammar@2 "$H" "$CB \"al${T}pha\" \"bin/a.sh\"" 'echo 1' "$CE"
dl_run "bash name CR" t.sh grammar@2 "$H" "$CB \"al${CR}pha\" \"bin/a.sh\"" 'echo 1' "$CE"
dl_run "bash value TAB" t.sh grammar@2 "$H" "$CB \"alpha\" \"bin/a${T}.sh\"" 'echo 1' "$CE"
dl_run "bash value CR" t.sh grammar@2 "$H" "$CB \"alpha\" \"bin/a${CR}.sh\"" 'echo 1' "$CE"
# The second case carries the delimiter: the rule reports the case that holds it.
dl_run "bash name TAB in the second case" t.sh grammar@5 "$H" "$CB \"alpha\" \"bin/a.sh\"" "$CE" '' \
  "$CB \"be${T}ta\" \"bin/b.sh\"" "$CE"
case_end

case_begin "bash-crlf-file-stays-conforming" "bin/lib/test-retire-predicate/case-parser.sh"
# Line-ending CRs sit outside the quotes, so they never reach a name or a value.
want="FILE${T}conforming${T}${T}
CASE${T}alpha${T}bin/a.sh${T}2${T}4${T}${T}
CASE${T}two words${T}bin/b.sh${T}6${T}8${T}${T}"
dl_run "bash CRLF file" t.sh "$want" "$H$CR" "$CB \"alpha\" \"bin/a.sh\"$CR" "echo 1$CR" "$CE$CR" "$CR" \
  "$CB \"two words\" \"bin/b.sh\"$CR" "echo 2$CR" "$CE$CR"
case_end

case_begin "pester-delimiters-are-grammar" "bin/lib/test-language-parts/pester-case-reader.ps1"
if need pwsh; then
  dl_run "pester name TAB" $P grammar@2 '$x = 1' "Describe \"al${BT}tpha\" -Tag 'target:bin/a.sh' {" '}'
  dl_run "pester name CR" $P grammar@2 '$x = 1' "Describe \"al${BT}rpha\" -Tag 'target:bin/a.sh' {" '}'
  dl_run "pester name LF" $P grammar@2 '$x = 1' "Describe \"al${BT}npha\" -Tag 'target:bin/a.sh' {" '}'
  dl_run "pester value TAB" $P grammar@2 '$x = 1' "Describe 'alpha' -Tag \"target:bin/a${BT}t.sh\" {" '}'
  dl_run "pester value CR" $P grammar@2 '$x = 1' "Describe 'alpha' -Tag \"target:bin/a${BT}r.sh\" {" '}'
  dl_run "pester value LF" $P grammar@2 '$x = 1' "Describe 'alpha' -Tag \"target:bin/a${BT}n.sh\" {" '}'
  dl_run "pester raw TAB in a single-quoted name" $P grammar@1 "Describe 'al${T}pha' -Tag 'target:bin/a.sh' {" '}'
  # Accept: a written backslash-t is two ordinary characters.
  dl_run "pester written backslash-t" $P "FILE${T}conforming${T}${T}
CASE${T}al\\tpha${T}bin/a.sh${T}1${T}2${T}${T}" "Describe 'al\\tpha' -Tag 'target:bin/a.sh' {" '}'
fi
case_end

case_begin "pytest-delimiters-are-grammar" "bin/lib/test-language-parts/pytest-case-reader.py"
if need uv; then
  dl_run "pytest value TAB" $Y grammar@4 'import pytest' '' '' '@pytest.mark.target("bin/a\t.sh")' 'def test_alpha():' '    assert True'
  dl_run "pytest value CR" $Y grammar@4 'import pytest' '' '' '@pytest.mark.target("bin/a\r.sh")' 'def test_alpha():' '    assert True'
  dl_run "pytest value LF" $Y grammar@4 'import pytest' '' '' '@pytest.mark.target("bin/a\n.sh")' 'def test_alpha():' '    assert True'
  dl_run "pytest value LF in a triple-quoted string" $Y grammar@4 'import pytest' '' '' '@pytest.mark.target("""bin/a' '.sh""")' 'def test_alpha():' '    assert True'
  # Accept: a raw string keeps the backslash, which the path rule (not the delimiter rule) rejects.
  dl_run "pytest raw-string backslash-t" $Y "FILE${T}malformed${T}4${T}target" 'import pytest' '' '' '@pytest.mark.target(r"bin/a\t.sh")' 'def test_alpha():' '    assert True'
fi
case_end

case_begin "js-delimiters-are-grammar" "bin/lib/test-language-parts/js-case-reader.js"
dl_run "js name TAB" $J grammar@2 'check(0);' "caseBegin(\"al${T}pha\", \"bin/a.sh\");" 'caseEnd();'
dl_run "js name CR" $J grammar@2 'check(0);' "caseBegin(\"al${CR}pha\", \"bin/a.sh\");" 'caseEnd();'
dl_run "js name LF" $J grammar@2 'check(0);' "caseBegin(${BT}al" "pha${BT}, \"bin/a.sh\");" 'caseEnd();'
dl_run "js value TAB" $J grammar@2 'check(0);' "caseBegin(\"alpha\", \"bin/a${T}.sh\");" 'caseEnd();'
dl_run "js value CR" $J grammar@2 'check(0);' "caseBegin(\"alpha\", \"bin/a${CR}.sh\");" 'caseEnd();'
dl_run "js value LF" $J grammar@2 'check(0);' "caseBegin(\"alpha\", ${BT}bin/a" ".sh${BT});" 'caseEnd();'
# Accept: an escaped backslash is the written text `\t`, not a TAB.
dl_run "js escaped backslash-t" $J "FILE${T}conforming${T}${T}
CASE${T}al\\tpha${T}bin/a.sh${T}1${T}2${T}${T}" 'caseBegin("al\\tpha", "bin/a.sh");' 'caseEnd();'
case_end

case_begin "runtime-crlf-files-stay-conforming" "bin/lib/test-retire-predicate/case-state-rules.sh"
# One single-case CRLF file per runtime language: conforming, the CR never in a field.
# (#2502 S1: every runtime language has caseEmbedRules, so a case without deps has an
# empty deps column, not `?`; the same holds for the accept rows above.)
dl_run "js CRLF file" $J "FILE${T}conforming${T}${T}
CASE${T}alpha${T}bin/a.sh${T}1${T}2${T}${T}" "caseBegin(\"alpha\", \"bin/a.sh\");$CR" "caseEnd();$CR"
if need pwsh; then
  dl_run "pester CRLF file" $P "FILE${T}conforming${T}${T}
CASE${T}alpha${T}bin/a.sh${T}1${T}2${T}${T}" "Describe 'alpha' -Tag 'target:bin/a.sh' {$CR" "}$CR"
fi
if need uv; then
  dl_run "pytest CRLF file" $Y "FILE${T}conforming${T}${T}
CASE${T}test_alpha${T}bin/a.sh${T}1${T}3${T}${T}" "@pytest.mark.target(\"bin/a.sh\")$CR" "def test_alpha():$CR" "    assert True$CR"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
