#!/usr/bin/env bash
# tests/bin/feature-2712-target-path-parity.sh
# Tests: bin/lib/case-target-path-rule.sh, bin/lib/test-retire-predicate/case-parser.sh, bin/lib/test-language-parts/pester-case-reader.ps1, bin/lib/test-language-parts/pytest-case-reader.py, bin/lib/test-language-parts/js-case-reader.js
# Tags: TL2, bin, case-markers, test-language-registry, scope:issue-specific, test-lang-exception:symmetry
# #2712: one target table runs through ctp_target_path_valid, the bash test case reader and the
# three test case reader child processes (through crr_read); every implementation gives the same verdict.
# TL3 gap: a missing runtime (pwsh / uv) prints `n/a` in its column and skips; CI hosts run all.
set -u

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

T=$'\t'
# The bash marker words, split so the sample lines below are not markers of this file.
CB="case_""begin" CE="case_""end"
CTP="$SCRIPT_CHECKOUT_ROOT/bin/lib/case-target-path-rule.sh"
HAVE_PWSH=0 HAVE_UV=0
command -v pwsh >/dev/null 2>&1 && HAVE_PWSH=1
command -v uv >/dev/null 2>&1 && HAVE_UV=1
N=0

# ctp <value> — ctp_target_path_valid's verdict: valid (rc 0) / invalid (rc 1) / absent / rc=<n>;
# a verdict with stdout carries `+stdout`.
ctp() {
  local out rc=0
  out="$(bash -c '. "$1" 2>/dev/null || exit 97; declare -F ctp_target_path_valid >/dev/null || exit 96; ctp_target_path_valid "$2"' _ "$CTP" "$1")" || rc=$?
  case "$rc" in
    0) printf valid ;;
    1) printf invalid ;;
    96 | 97) printf absent ;;
    *) printf 'rc=%s' "$rc" ;;
  esac
  [ -z "$out" ] || printf '+stdout'
}

# reader <file-name> <line>... — writes the lines to a fresh file and maps crr_read's output to
# valid (conforming) / invalid (malformed <n> target) / other:<output>.
reader() {
  local name="$1" dir out
  shift
  N=$((N + 1))
  dir="$TMPBASE/s$N"
  mkdir -p "$dir"
  printf '%s\n' "$@" >"$dir/$name"
  out="$(run_with_timeout 120 bash -c '. "$1/bin/lib/case-record-reader.sh" || exit 97; crr_read "$2"' _ "$SCRIPT_CHECKOUT_ROOT" "$dir/$name" 2>/dev/null)"
  case "$out" in
    "FILE${T}conforming${T}${T}"*) printf valid ;;
    "FILE${T}malformed${T}"*"${T}target") printf invalid ;;
    *) printf 'other:%q' "$out" ;;
  esac
}

# verdicts <value> — `ctp=… bash=… pester=… pytest=… js=…` for one target value.
verdicts() {
  local v="$1" p=n/a y=n/a
  [ "$HAVE_PWSH" = 1 ] && p="$(reader t.Tests.ps1 "Describe 'alpha' -Tag 'target:$v' {" '}')"
  [ "$HAVE_UV" = 1 ] && y="$(reader test_t.py "@pytest.mark.target(\"$v\")" 'def test_alpha():' '    assert True')"
  printf 'ctp=%s bash=%s pester=%s pytest=%s js=%s' "$(ctp "$v")" \
    "$(reader t.sh '#!/usr/bin/env bash' "$CB \"alpha\" \"$v\"" 'echo 1' "$CE")" \
    "$p" "$y" "$(reader t.js "caseBegin(\"alpha\", \"$v\");" 'caseEnd();')"
}

# row <label> <value> <valid|invalid> — every implementation agrees on <want>.
row() {
  local want="$3" p="$3" y="$3"
  [ "$HAVE_PWSH" = 1 ] || p=n/a
  [ "$HAVE_UV" = 1 ] || y=n/a
  assert_eq "$1 [$2]: $(verdicts "$2")" "$1 [$2]: ctp=$want bash=$want pester=$p pytest=$y js=$want"
}

# rows <valid|invalid> — every table row with that verdict through row; fails on an empty set.
rows() {
  local label value want n=0
  # The table is on fd 3 so a reader child can never drain it from stdin.
  while IFS='|' read -r label value want <&3; do
    [ "$want" = "$1" ] || continue
    n=$((n + 1))
    row "$label" "$value" "$want"
  done 3<<'ROWS'
normal|bin/a.sh|valid
nested|bin/lib/b-c_d.ps1|valid
dotted name|bin/a..b.sh|valid
hidden file|bin/.hidden|valid
absolute|/abs/a.sh|invalid
leading ./|./x.sh|invalid
parent segment|a/../b.sh|invalid
space|bin/a b.sh|invalid
bare ..|..|invalid
leading ..|../x.sh|invalid
trailing ..|bin/..|invalid
ROWS
  [ "$n" -gt 0 ] || fail "$1 rows" "no $1 row in the table"
}

case_begin "path-rule-library-present" "bin/lib/case-target-path-rule.sh"
# ctp_target_path_valid answers by rc only: no stdout on either verdict.
assert_eq "valid: $(ctp bin/a.sh)" "valid: valid"
assert_eq "invalid: $(ctp /abs/a.sh)" "invalid: invalid"
case_end

case_begin "valid-targets-agree" "bin/lib/case-target-path-rule.sh"
# Accept: `..` inside a segment name and a leading-dot file are not a parent step.
rows valid
case_end

case_begin "invalid-targets-agree" "bin/lib/case-target-path-rule.sh"
[ "$HAVE_PWSH" = 1 ] || skip "pwsh not available: pester column is n/a"
[ "$HAVE_UV" = 1 ] || skip "uv not available: pytest column is n/a"
rows invalid
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
