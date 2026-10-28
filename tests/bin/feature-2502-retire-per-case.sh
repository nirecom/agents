#!/usr/bin/env bash
# tests/bin/feature-2502-retire-per-case.sh
# Tests: bin/lib/test-retire-predicate.sh, bin/lib/test-retire-predicate/orphan-removal.sh
# Tags: TL2, bin, case-markers, test-language-registry, audit-tests, pytest, pester, js, scope:issue-specific
# Per-case retirement beyond bash: trp_remove_orphan_cases moves to
# test-retire-predicate/orphan-removal.sh and checks the rewritten file with the entry's
# caseEmbedRules `syntax-check` op instead of `bash -n`. A pytest, Pester or js file with one
# orphan case gets partial-orphan / case mode, the orphan case is cut, the rest still parses
# and is staged; a refusing syntax-check (or, for pytest, a missing runtime) leaves the file
# untouched. The bash path keeps its behaviour.
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

# fx_checkout / path_without / has_line: the registry suite's helpers (one owner).
# shellcheck source=test-language-registry/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/test-language-registry/_lib.sh"

PY_REL=tests/bin/test_feature-9999-sample.py
SH_REL=tests/bin/feature-9999-sample.sh
PS_REL=tests/bin/feature-9999-sample.Tests.ps1
JS_REL=tests/bin/feature-9999-sample.js
# The bash sample's marker words, split so this file's own marker gate never reads them.
MB='case_''begin' ME='case_''end'
# The samples' header lines, split so this file has a single header of its own.
FX_TESTS='# ''Tests: bin/a.sh, bin/gone.sh, bin/b.sh'
FX_TAGS='# ''Tags: TL2, scope:issue-specific'

# A checkout whose bin/a.sh and bin/b.sh exist and bin/gone.sh does not; each sample has
# three cases, the middle one targeting bin/gone.sh.
BASE="$TMPBASE/base"
fx_checkout "$BASE"
cp "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.py" "$BASE/tests/lib/harness.py"
mkdir -p "$BASE/tests/bin"
printf '#!/usr/bin/env bash\necho a\n' >"$BASE/bin/a.sh"
printf '#!/usr/bin/env bash\necho b\n' >"$BASE/bin/b.sh"
{
printf '%s\n' "$FX_TESTS" "$FX_TAGS"
cat <<'PY'
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness  # noqa: E402,F401


def helper_alpha():
    return 1


@pytest.mark.target("bin/a.sh")
def test_alpha():
    assert helper_alpha() == 1


@pytest.mark.target("bin/gone.sh")
def test_gone():
    assert True


@pytest.mark.target("bin/b.sh")
def test_beta():
    assert helper_alpha() == 1
PY
} >"$BASE/$PY_REL"
sh_case() {
  printf '\n%s "%s" "bin/%s.sh"\npass "%s"\n%s\n' "$MB" "$1" "$2" "$1" "$ME"
}
{
  printf '%s\n' '#!/usr/bin/env bash' "$FX_TESTS" "$FX_TAGS" 'set -u' 'source "$(dirname "$0")/../lib/harness.sh"'
  sh_case alpha a
  sh_case gone gone
  sh_case beta b
} >"$BASE/$SH_REL"
cp "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.ps1" "$BASE/tests/lib/harness.ps1"
cp "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.js" "$BASE/tests/lib/harness.js"
{
printf '%s\n' "$FX_TESTS" "$FX_TAGS"
cat <<'PS1'
BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
    function Get-Alpha { return 1 }
}

Describe 'alpha' -Tag 'target:bin/a.sh' {
    It 'uses alpha' { Get-Alpha | Should -Be 1 }
}

Describe 'gone' -Tag 'target:bin/gone.sh' {
    It 'is gone' { 1 | Should -Be 1 }
}

Describe 'beta' -Tag 'target:bin/b.sh' {
    It 'uses alpha' { Get-Alpha | Should -Be 1 }
}
PS1
} >"$BASE/$PS_REL"
cat >"$BASE/$JS_REL" <<'JS'
"use strict";
// Tests: bin/a.sh, bin/gone.sh, bin/b.sh
// Tags: TL2, scope:issue-specific
const { test } = require("node:test");
const assert = require("node:assert");
const { caseBegin, caseEnd } = require("../lib/harness");

function helperAlpha() {
  return 1;
}

caseBegin("alpha", "bin/a.sh");
test("alpha", () => {
  assert.strictEqual(helperAlpha(), 1);
});
caseEnd();

caseBegin("gone", "bin/gone.sh");
test("gone", () => {
  assert.ok(true);
});
caseEnd();

caseBegin("beta", "bin/b.sh");
test("beta", () => {
  assert.strictEqual(helperAlpha(), 1);
});
caseEnd();
JS
git -C "$BASE" add -A >/dev/null
git -C "$BASE" commit -q -m fixture

# fresh <name> — prints the path of a new copy of BASE (its .git included).
fresh() {
  rm -rf "${TMPBASE:?}/$1"
  cp -R "$BASE" "$TMPBASE/$1"
  printf '%s' "$TMPBASE/$1"
}

# refuse_syntax_check <checkout> <id> — wrap the entry's caseEmbedRules function in the
# checkout so its syntax-check op answers rc 1 and every other op is delegated.
refuse_syntax_check() {
  local f="$1/bin/lib/test-language-parts/$2-case-embed.sh" fn="$2_case_embed"
  printf '%s\n' "" \
    "eval \"_stub_real_\$(declare -f $fn)\"" \
    "$fn() {" \
    "  if [ \"\${1:-}\" = syntax-check ]; then echo 'stub: syntax-check refused' >&2; return 1; fi" \
    "  _stub_real_$fn \"\$@\"" \
    "}" >>"$f"
}

# retire <checkout> <rel> <path|-> [sed-expr] — verdict, then (sed -i <sed-expr> on <rel>; PATH=<path>,
# "-" keeps it) removal, in ONE shell. Prints VERDICT/MODE/ORPHANS, the removal's stdout, then RC=<n>.
retire() {
  run_with_timeout 120 bash -c '. "$1/bin/lib/test-retire-predicate.sh" || exit 97
cd "$1" || exit 98
trp_case_refcount_verdict "$1" "$2" >/dev/null
printf "VERDICT=%s MODE=%s ORPHANS=%s\n" "$TRP_VERDICT" "$TRP_UNIT_MODE" "${TRP_ORPHAN_CASE_IDX[*]:-}"
[[ -z "${4:-}" ]] || sed -i "$4" "$2" || exit 96
[ "$3" = - ] || PATH="$3"
r=0; trp_remove_orphan_cases "$1" "$2" || r=$?
echo "RC=$r"' _ "$@" 2>"$TMPBASE/retire.err"
}

# py_parses <file> — rc 0 when Python's ast.parse accepts it.
py_parses() {
  uv run --no-project python -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$(np "$1")" >/dev/null 2>&1
}

# ps_parses <file> — rc 0 when the PowerShell parser reports no error.
PS_PARSE="$TMPBASE/ps-parse.ps1"
printf '%s\n' '$e = $null' '[void][System.Management.Automation.Language.Parser]::ParseFile($args[0], [ref]$null, [ref]$e)' 'if ($e.Count) { exit 1 }' 'exit 0' >"$PS_PARSE"
ps_parses() {
  run_with_timeout 120 pwsh -NoProfile -NonInteractive -File "$(np "$PS_PARSE")" "$(np "$1")" >/dev/null 2>&1
}

# survivors_kept <label> <original> <result> — <result> is <original> with only the lines of each
# case targeting bin/gone.sh cut: every other byte (surviving cases, non-case remainder) is kept.
survivors_kept() {
  local cut
  case "$2" in
    *.py) cut='/^@pytest\.mark\.target("bin\/gone\.sh")$/,/^    assert /d' ;;
    *.Tests.ps1) cut="/^Describe '[a-z]*' -Tag 'target:bin\/gone\.sh' {\$/,/^}\$/d" ;;
    *.js) cut='/^caseBegin("[a-z]*", "bin\/gone\.sh");$/,/^caseEnd();$/d' ;;
    *) cut="/^$MB \"[a-z]*\" \"bin\/gone\.sh\"\$/,/^$ME\$/d" ;;
  esac
  sed "$cut" "$2" >"$TMPBASE/survivors.want"
  if cmp -s "$TMPBASE/survivors.want" "$3"; then pass "$1: surviving bytes identical to the original"; else fail "$1: surviving bytes identical to the original" "$(diff "$TMPBASE/survivors.want" "$3" | head -c 300)"; fi
}

# check_removed <label> <checkout> <rel> <parse-fn> <case-line-regex> <kept-def-regex>
# <orphan-marker-regex> — the orphan-removal assertions every language shares: verdict, rc 0,
# the file parses, two cases and the helper stay, the orphan's marker is gone, only <rel> is staged.
check_removed() {
  local label="$1" co="$2" rel="$3" parse="$4" case_re="$5" def_re="$6" gone_re="$7" out
  out="$(retire "$co" "$rel" -)"
  has_line "$label verdict is partial-orphan in case mode" "$out" "VERDICT=partial-orphan MODE=case ORPHANS=1"
  has_line "$label removal rc 0" "$out" "RC=0"
  if "$parse" "$co/$rel"; then pass "$label: the rewritten file parses"; else fail "$label: the rewritten file parses" "$parse failed / $(head -c 200 "$TMPBASE/retire.err")"; fi
  assert_eq "$label cases left: $(grep -cE "$case_re" "$co/$rel"), helper defs: $(grep -cE "$def_re" "$co/$rel"), gone left: $(grep -cE "$gone_re" "$co/$rel")" \
    "$label cases left: 2, helper defs: 1, gone left: 0"
  survivors_kept "$label" "$BASE/$rel" "$co/$rel"
  assert_eq "$label staged: $(git -C "$co" diff --cached --name-only)" "$label staged: $rel"
}

# check_refused <label> <id> <rel> — a refusing syntax-check fails the removal, file untouched.
check_refused() {
  local co out
  co="$(fresh "$2-refuse")"
  refuse_syntax_check "$co" "$2"
  out="$(retire "$co" "$3" -)"
  has_line "$1: the verdict still asks for case removal" "$out" "VERDICT=partial-orphan MODE=case ORPHANS=1"
  has_line "$1: a refusing syntax-check fails the removal" "$out" "RC=1"
  if cmp -s "$BASE/$3" "$co/$3"; then pass "$1: the file is unchanged"; else fail "$1: the file is unchanged" "rewritten"; fi
  assert_eq "$1 staged: [$(git -C "$co" diff --cached --name-only)]" "$1 staged: []"
}

js_parses() {
  node --check "$(np "$1")" >/dev/null 2>&1
}

bash_parses() {
  bash -n "$1" 2>/dev/null
}

# check_rerun <label> <rel> <case-line-regex> — retire twice on one copy: the second run finds no
# orphan case, so the removal fails closed (rc 1, "no orphan case state", no name printed) and
# changes neither the file bytes, nor the cases left, nor the staged paths.
check_rerun() {
  local label="$1" rel="$2" case_re="$3" co out cases staged
  co="$(fresh "rerun-$label")"
  out="$(retire "$co" "$rel" -)"
  has_line "$label first run removes the orphan case" "$out" "RC=0"
  cp "$co/$rel" "$TMPBASE/rerun-$label.snap"
  cases="$(grep -cE "$case_re" "$co/$rel")"
  staged="$(git -C "$co" diff --cached --name-only)"
  out="$(retire "$co" "$rel" -)"
  has_line "$label second run: alive, case mode, no orphan left" "$out" "VERDICT=alive MODE=case ORPHANS="
  assert_eq "$label second run output: $(printf '%s' "$out" | tr '\n' ' ')" \
    "$label second run output: VERDICT=alive MODE=case ORPHANS= RC=1"
  if grep -q 'no orphan case state' "$TMPBASE/retire.err"; then pass "$label second run: refusal names the missing orphan state"; else fail "$label second run: refusal names the missing orphan state" "$(head -c 200 "$TMPBASE/retire.err")"; fi
  if cmp -s "$TMPBASE/rerun-$label.snap" "$co/$rel"; then pass "$label second run: file bytes unchanged"; else fail "$label second run: file bytes unchanged" "rewritten again"; fi
  assert_eq "$label after the second run: cases left $(grep -cE "$case_re" "$co/$rel"), staged [$(git -C "$co" diff --cached --name-only)]" \
    "$label after the second run: cases left $cases, staged [$staged]"
}

case_begin "removal-lives-in-orphan-removal" "bin/lib/test-retire-predicate/orphan-removal.sh"
F="$SCRIPT_CHECKOUT_ROOT/bin/lib/test-retire-predicate/orphan-removal.sh"
if [ -f "$F" ] && grep -q '^trp_remove_orphan_cases()' "$F"; then
  pass "orphan-removal.sh defines trp_remove_orphan_cases"
else
  fail "orphan-removal.sh defines trp_remove_orphan_cases" "missing file or definition"
fi
n="$(grep -c 'bash -n "\$tmp"' "$SCRIPT_CHECKOUT_ROOT/bin/lib/test-retire-predicate.sh")"
assert_eq "bash -n on the rewrite left in test-retire-predicate.sh: $n" "bash -n on the rewrite left in test-retire-predicate.sh: 0"
n="$(grep -c 'bash -n' "$F" 2>/dev/null)"
assert_eq "bash -n in orphan-removal.sh: ${n:-0}" "bash -n in orphan-removal.sh: 0"
case_end

case_begin "pytest-partial-orphan-removed" "bin/lib/test-retire-predicate.sh"
if command -v uv >/dev/null 2>&1; then
  CO="$(fresh py-ok)"
  OUT="$(retire "$CO" "$PY_REL" -)"
  has_line "pytest verdict is partial-orphan in case mode" "$OUT" "VERDICT=partial-orphan MODE=case ORPHANS=1"
  has_line "pytest removal rc 0" "$OUT" "RC=0"
  if printf '%s\n' "$OUT" | grep -q 'test_gone'; then pass "removal names test_gone"; else fail "removal names test_gone" "$(printf '%s' "$OUT" | tr '\n' ' ') / $(head -c 200 "$TMPBASE/retire.err")"; fi
  if py_parses "$CO/$PY_REL"; then pass "the rewritten file parses"; else fail "the rewritten file parses" "ast.parse failed"; fi
  got="$(grep -cE '^def (test_alpha|test_beta|helper_alpha)\(' "$CO/$PY_REL")"
  assert_eq "kept defs: $got, test_gone left: $(grep -cE 'def test_gone|target\("bin/gone.sh"\)' "$CO/$PY_REL")" "kept defs: 3, test_gone left: 0"
  survivors_kept pytest "$BASE/$PY_REL" "$CO/$PY_REL"
  assert_eq "staged: $(git -C "$CO" diff --cached --name-only)" "staged: $PY_REL"
else
  skip "pytest removal: uv not available"
fi
case_end

case_begin "pytest-syntax-check-refusal-keeps-file" "bin/lib/test-retire-predicate/orphan-removal.sh"
if command -v uv >/dev/null 2>&1; then
  CO="$(fresh py-refuse)"
  refuse_syntax_check "$CO" pytest
  OUT="$(retire "$CO" "$PY_REL" -)"
  has_line "the verdict still asks for case removal" "$OUT" "VERDICT=partial-orphan MODE=case ORPHANS=1"
  has_line "a refusing syntax-check fails the removal" "$OUT" "RC=1"
  if cmp -s "$BASE/$PY_REL" "$CO/$PY_REL"; then pass "the file is unchanged"; else fail "the file is unchanged" "rewritten"; fi
  assert_eq "staged: [$(git -C "$CO" diff --cached --name-only)]" "staged: []"
else
  skip "pytest refusal: uv not available"
fi
case_end

case_begin "pytest-runtime-missing-keeps-file" "bin/lib/test-retire-predicate/orphan-removal.sh"
if command -v uv >/dev/null 2>&1; then
  CO="$(fresh py-noruntime)"
  OUT="$(retire "$CO" "$PY_REL" "$(path_without uv)")"
  has_line "the verdict is taken with uv on PATH" "$OUT" "VERDICT=partial-orphan MODE=case ORPHANS=1"
  has_line "without uv the syntax-check cannot run: no removal" "$OUT" "RC=1"
  if cmp -s "$BASE/$PY_REL" "$CO/$PY_REL"; then pass "the file is unchanged"; else fail "the file is unchanged" "rewritten"; fi
else
  skip "pytest runtime-missing: uv not available"
fi
case_end

case_begin "bash-partial-orphan-unchanged" "bin/lib/test-retire-predicate/orphan-removal.sh"
# Regression: the bash path still cuts the orphan case and stages the result.
CO="$(fresh sh-ok)"
OUT="$(retire "$CO" "$SH_REL" -)"
has_line "bash verdict is partial-orphan in case mode" "$OUT" "VERDICT=partial-orphan MODE=case ORPHANS=1"
has_line "bash removal rc 0" "$OUT" "RC=0"
if printf '%s\n' "$OUT" | grep -q 'gone'; then pass "removal names gone"; else fail "removal names gone" "$(printf '%s' "$OUT" | tr '\n' ' ') / $(head -c 200 "$TMPBASE/retire.err")"; fi
if bash -n "$CO/$SH_REL" 2>/dev/null; then pass "the rewritten bash file parses"; else fail "the rewritten bash file parses" "bash -n failed"; fi
assert_eq "cases left: $(grep -c "^$MB" "$CO/$SH_REL"), gone left: $(grep -c 'bin/gone.sh"' "$CO/$SH_REL")" "cases left: 2, gone left: 0"
survivors_kept bash "$BASE/$SH_REL" "$CO/$SH_REL"
assert_eq "staged: $(git -C "$CO" diff --cached --name-only)" "staged: $SH_REL"
case_end

case_begin "bash-syntax-check-refusal-keeps-file" "bin/lib/test-retire-predicate/orphan-removal.sh"
# The bash rewrite is checked through the same op: a refusing bash syntax-check stops it.
CO="$(fresh sh-refuse)"
refuse_syntax_check "$CO" bash
OUT="$(retire "$CO" "$SH_REL" -)"
has_line "a refusing bash syntax-check fails the removal" "$OUT" "RC=1"
if cmp -s "$BASE/$SH_REL" "$CO/$SH_REL"; then pass "the bash file is unchanged"; else fail "the bash file is unchanged" "rewritten"; fi
case_end

case_begin "pester-partial-orphan-removed" "bin/lib/test-retire-predicate.sh"
if command -v pwsh >/dev/null 2>&1; then
  check_removed pester "$(fresh ps-ok)" "$PS_REL" ps_parses "^Describe '" '^ +function Get-Alpha ' "target:bin/gone\.sh|^Describe 'gone'"
else
  skip "pester removal: pwsh not available"
fi
case_end

case_begin "pester-syntax-check-refusal-keeps-file" "bin/lib/test-retire-predicate/orphan-removal.sh"
if command -v pwsh >/dev/null 2>&1; then
  check_refused pester pester "$PS_REL"
else
  skip "pester refusal: pwsh not available"
fi
case_end

case_begin "js-partial-orphan-removed" "bin/lib/test-retire-predicate.sh"
check_removed js "$(fresh js-ok)" "$JS_REL" js_parses '^caseBegin\(' '^function helperAlpha\(' 'caseBegin\("gone"|^test\("gone"'
case_end

case_begin "js-syntax-check-refusal-keeps-file" "bin/lib/test-retire-predicate/orphan-removal.sh"
check_refused js js "$JS_REL"
case_end

case_begin "rerun-is-idempotent" "bin/lib/test-retire-predicate/orphan-removal.sh"
check_rerun bash "$SH_REL" "^$MB "
check_rerun js "$JS_REL" '^caseBegin\('
if command -v uv >/dev/null 2>&1; then check_rerun pytest "$PY_REL" '^def test_'; else skip "pytest rerun: uv not available"; fi
if command -v pwsh >/dev/null 2>&1; then check_rerun pester "$PS_REL" "^Describe '"; else skip "pester rerun: pwsh not available"; fi
case_end

# The remaining cases live in the sibling suite directory (file split at the size limit).
GROUP_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2502-retire-per-case"
for g in multi-orphan-and-cut-guards js-esm-module; do
  if [ -f "$GROUP_DIR/$g.sh" ]; then
    # shellcheck source=/dev/null
    . "$GROUP_DIR/$g.sh"
  else
    fail "dispatch: group file missing: $g.sh" "$GROUP_DIR"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
