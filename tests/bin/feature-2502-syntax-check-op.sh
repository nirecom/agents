#!/usr/bin/env bash
# tests/bin/feature-2502-syntax-check-op.sh
# Tests: bin/lib/test-language-parts/bash-case-embed.sh, bin/lib/test-language-parts/pester-case-embed.sh, bin/lib/test-language-parts/pytest-case-embed.sh, bin/lib/test-language-parts/js-case-embed.sh, bin/lib/test-language-parts/pester-case-analyzer.ps1, bin/lib/test-language-parts/pytest-case-analyzer.py, bin/lib/test-language-parts/js-case-analyzer.js
# Tags: TL2, bin, case-markers, test-language-registry, sweep-tests, pester, pytest, js, test-lang-exception:symmetry, scope:issue-specific
# The caseEmbedRules `syntax-check <abs>` op of all four languages (bash -n, pester ParseFile
# errors, pytest ast.parse, js node --check): a valid file gives rc 0 and no stdout, a broken
# one rc 1 with no stdout and a message on stderr, a hidden runtime rc 69; the op is resolved
# through tlr_match, never by extension. Pester's syntax-check never touches the
# CASE_EMBED_CACHE_DIR cache. One bash test drives all four languages' parts and analyzers,
# hence test-lang-exception:symmetry.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
export HOME="$TMPBASE/home"
mkdir -p "$HOME"
export NO_LOG=true
harness_isolate "$TMPBASE/state"
unset CASE_EMBED_CACHE_DIR

# path_without: the registry suite's helper (one owner).
# shellcheck source=test-language-registry/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/test-language-registry/_lib.sh"

B="$TMPBASE/tests/bin"
mkdir -p "$B"
printf '#!/usr/bin/env bash\nset -u\necho ok\n' >"$B/syn_ok.sh"
printf '#!/usr/bin/env bash\nf() {\n  echo unterminated\n' >"$B/syn_bad.sh"
printf "Describe 'x' {\n    It 'y' { 1 | Should -Be 1 }\n}\n" >"$B/ok.Tests.ps1"
printf "Describe 'x' {\n    It 'y' { 1 | Should -Be 1\n" >"$B/bad.Tests.ps1"
printf 'def test_x():\n    assert True\n' >"$B/test_ok.py"
printf 'def test_x(:\n    assert True\n' >"$B/test_bad.py"
printf '"use strict";\nconst a = 1;\nmodule.exports = { a };\n' >"$B/ok.js"
printf '"use strict";\nfunction f( {\n' >"$B/bad.js"

# syn <path|-> <file>... — ONE shell: load the registry, tlr_match each file, run its entry's
# `caseEmbedRules syntax-check <file>` with PATH=<path> ("-" keeps it). Prints
# "@@ <basename> id=<id> rc=<n> out=<stdout> errbytes=<stderr length>" per file.
SYN_RUNNER="$TMPBASE/syn-runner.sh"
cat >"$SYN_RUNNER" <<'RUN'
. "$1/bin/lib/test-language-registry.sh" || exit 97
tlr_load || exit 96
p="$2"; shift 2
for f in "$@"; do
  tlr_match "$f" || { printf "@@ %s id=none\n" "${f##*/}"; continue; }
  id="$TLR_ID" r=0
  [ "$p" = - ] || { op="$PATH"; PATH="$p"; }
  out="$(tlr_call_part "$id" caseEmbedRules syntax-check "$f" 2>"$f.err")" || r=$?
  [ "$p" = - ] || PATH="$op"
  printf "@@ %s id=%s rc=%s out=%s errbytes=%s\n" "${f##*/}" "$id" "$r" "$out" "$(wc -c <"$f.err" | tr -d " ")"
done
RUN
syn() {
  run_with_timeout 120 bash "$SYN_RUNNER" "$SCRIPT_CHECKOUT_ROOT" "$@" 2>"$TMPBASE/syn.err"
}

# line_of <out> <basename> — the "@@ <basename> ..." line without the leading "@@ ".
line_of() {
  printf '%s\n' "$1" | awk -v b="@@ $2 " 'index($0, b) == 1 { print substr($0, 4); exit }'
}

# rc_out_of <out> <basename> — "id=<id> rc=<n> out=<stdout>".
rc_out_of() {
  line_of "$1" "$2" | sed -e 's/^[^ ]* //' -e 's/ errbytes=.*$//'
}

# errbytes_of <out> <basename>
errbytes_of() {
  line_of "$1" "$2" | sed -n 's/.* errbytes=//p'
}

# check_lang <id> <runtime|-> <ok-file> <bad-file>
check_lang() {
  local id="$1" rt="$2" ok="$3" bad="$4" out n
  if [ "$rt" != - ] && ! command -v "$rt" >/dev/null 2>&1; then
    skip "$id syntax-check: $rt not available"
    return 0
  fi
  out="$(syn - "$B/$ok" "$B/$bad")"
  assert_eq "$ok: $(rc_out_of "$out" "$ok")" "$ok: id=$id rc=0 out="
  assert_eq "$bad: $(rc_out_of "$out" "$bad")" "$bad: id=$id rc=1 out="
  n="$(errbytes_of "$out" "$bad")"
  if [ "${n:-0}" -gt 0 ]; then pass "$bad: stderr carries the parse error"; else fail "$bad: stderr carries the parse error" "stderr empty; $(head -c 200 "$TMPBASE/syn.err")"; fi
  [ "$rt" = - ] && return 0
  out="$(syn "$(path_without "$rt")" "$B/$ok" "$B/$bad")"
  assert_eq "$ok without $rt: $(rc_out_of "$out" "$ok")" "$ok without $rt: id=$id rc=69 out="
  assert_eq "$bad without $rt: $(rc_out_of "$out" "$bad")" "$bad without $rt: id=$id rc=69 out="
}

case_begin "bash-syntax-check" "bin/lib/test-language-parts/bash-case-embed.sh"
check_lang bash - syn_ok.sh syn_bad.sh
case_end

case_begin "pester-syntax-check" "bin/lib/test-language-parts/pester-case-embed.sh"
check_lang pester pwsh ok.Tests.ps1 bad.Tests.ps1
case_end

case_begin "pytest-syntax-check" "bin/lib/test-language-parts/pytest-case-embed.sh"
check_lang pytest uv test_ok.py test_bad.py
case_end

case_begin "js-syntax-check" "bin/lib/test-language-parts/js-case-embed.sh"
check_lang js node ok.js bad.js
case_end

case_begin "pester-syntax-check-not-cached" "bin/lib/test-language-parts/pester-case-embed.sh"
# With CASE_EMBED_CACHE_DIR set, syntax-check still answers from the file (a broken file is
# rc 1) and writes nothing into the cache directory.
if command -v pwsh >/dev/null 2>&1; then
  mkdir -p "$TMPBASE/cache"
  out="$(CASE_EMBED_CACHE_DIR="$TMPBASE/cache" syn - "$B/ok.Tests.ps1" "$B/bad.Tests.ps1")"
  assert_eq "cached run: $(rc_out_of "$out" ok.Tests.ps1) / $(rc_out_of "$out" bad.Tests.ps1)" "cached run: id=pester rc=0 out= / id=pester rc=1 out="
  assert_eq "cache files after syntax-check=$(find "$TMPBASE/cache" -type f | grep -c .)" "cache files after syntax-check=0"
else
  skip "pester cache: pwsh not available"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
