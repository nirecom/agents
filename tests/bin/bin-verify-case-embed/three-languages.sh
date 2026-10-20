# Three languages (pester, pytest, js): one faithful rewrite per language passes checks 1-5
# (check 2 with counts from the result-summary op), and checks 3 / 5 catch a leftover
# definition and a redefined helper through the language's caseEmbedRules part. Sourced by
# the dispatcher. A language whose runtime is off PATH is skipped.
# TL3 gap: real corpus rewrites by the embed subagent in these languages are only met when
# the first band is embedded.

echo ""
echo "=== three languages, checks 1-5 ==="

WD3="$TMPBASE/work3"
mkdir -p "$WD3"

# Per language: before (no markers), good (one case per header token), bad (good plus a
# top-level definition no case uses and a redefinition of a helper export; one verifier run
# answers checks 3 and 5, which keeps the dispatcher's runtime down).
cat >"$WD3/pester-before" <<'FX'
# Tests: bin/a.sh, bin/b.sh
# Tags: TL2, scope:common
BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
}

Describe 'sample' {
    It 'a works' { 1 | Should -Be 1 }
    It 'b works' { 2 | Should -Be 2 }
}
FX
cat >"$WD3/pester-good" <<'FX'
# Tests: bin/a.sh, bin/b.sh
# Tags: TL2, scope:common
BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
}

Describe 'a' -Tag 'target:bin/a.sh' {
    It 'a works' { 1 | Should -Be 1 }
}

Describe 'b' -Tag 'target:bin/b.sh' {
    It 'b works' { 2 | Should -Be 2 }
}
FX
{ cat "$WD3/pester-good"; printf '\nfunction Get-Unused { return 3 }\n\nfunction Enter-HarnessIsolation { return 1 }\n'; } >"$WD3/pester-bad"

cat >"$WD3/pytest-before" <<'FX'
# Tests: bin/a.sh, bin/b.sh
# Tags: TL2, scope:common
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness  # noqa: E402,F401


def test_a():
    assert 1 == 1


def test_b():
    assert 2 == 2
FX
cat >"$WD3/pytest-good" <<'FX'
# Tests: bin/a.sh, bin/b.sh
# Tags: TL2, scope:common
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness  # noqa: E402,F401


@pytest.mark.target("bin/a.sh")
def test_a():
    assert 1 == 1


@pytest.mark.target("bin/b.sh")
def test_b():
    assert 2 == 2
FX
{ cat "$WD3/pytest-good"; printf '\n\ndef helper_unused():\n    return 9\n\n\ndef isolate():\n    return 1\n'; } >"$WD3/pytest-bad"

cat >"$WD3/js-before" <<'FX'
"use strict";
// Tests: bin/a.sh, bin/b.sh
// Tags: TL2, scope:common
require("../lib/harness");
const { test } = require("node:test");
const assert = require("node:assert");

test("a works", () => {
  assert.strictEqual(1, 1);
});

test("b works", () => {
  assert.strictEqual(2, 2);
});
FX
cat >"$WD3/js-good" <<'FX'
"use strict";
// Tests: bin/a.sh, bin/b.sh
// Tags: TL2, scope:common
const { caseBegin, caseEnd } = require("../lib/harness");
const { test } = require("node:test");
const assert = require("node:assert");

caseBegin("a", "bin/a.sh");
test("a works", () => {
  assert.strictEqual(1, 1);
});
caseEnd();

caseBegin("b", "bin/b.sh");
test("b works", () => {
  assert.strictEqual(2, 2);
});
caseEnd();
FX
{ cat "$WD3/js-good"; printf '\nfunction helperUnused() {\n  return 9;\n}\n\nfunction isolate() {\n  return 1;\n}\n'; } >"$WD3/js-bad"

# lang3 <id> — L3_REL (the file's repo path), L3_RT (runtime), L3_LEFT (the leftover name),
# L3_REDEF (the redefined helper export).
lang3() {
  case "$1" in
    pester) L3_REL=tests/bin/sample.Tests.ps1 L3_RT=pwsh L3_LEFT=Get-Unused L3_REDEF=Enter-HarnessIsolation ;;
    pytest) L3_REL=tests/bin/test_sample.py L3_RT=uv L3_LEFT=helper_unused L3_REDEF=isolate ;;
    js) L3_REL=tests/bin/sample.js L3_RT=node L3_LEFT=helperUnused L3_REDEF=isolate ;;
  esac
}

# The checkout: the real table, every language's helper library, each before file at its path.
VCO3="$TMPBASE/co3"
vce_checkout "$VCO3"
for f in harness.ps1 harness.py harness.js; do cp "$SCRIPT_CHECKOUT_ROOT/tests/lib/$f" "$VCO3/tests/lib/$f"; done
for id in pester pytest js; do
  lang3 "$id"
  cp "$WD3/$id-before" "$VCO3/$L3_REL"
done
git -C "$VCO3" add -A >/dev/null 2>&1
git -C "$VCO3" commit -q -m three-languages >/dev/null 2>&1

# vce3 <id> <variant> [extra args...] — the verifier on <variant> at that language's path,
# with a fresh backup dir (V_BK). rc 1 (and a SKIP line) when the runtime is off PATH.
vce3() {
  local id="$1" v="$2"
  shift 2
  lang3 "$id"
  if ! command -v "$L3_RT" >/dev/null 2>&1; then skip "$id: $L3_RT not available"; return 1; fi
  V_BK="$(mktemp -d "$TMPBASE/bk.XXXXXX")"
  vce "$VCO3" "$WD3/$id-$v" --relpath "$L3_REL" --backup-dir "$V_BK" "$@"
}

# all_checks <id> — the faithful rewrite passes checks 1-5; check 2 carries counts 2/0.
all_checks() {
  local id="$1" ids n
  vce3 "$id" good --before "$WD3/$id-before" || return 0
  assert_eq "$id rc=$V_RC" "$id rc=0"
  ids="$(printf '%s\n' "$V_OUT" | awk -F'\t' '$1 ~ /^CHECK/ { print substr($1, 6) }' | tr '\n' ' ')"
  assert_eq "$id checks run: $ids" "$id checks run: 1 2 3 4 5 "
  for n in 1 2 3 4 5; do expect_check "$id good" "$n" PASS; done
  detail_has "$id good" 2 "counts 2/0"
  detail_has "$id good" 3 "no leftover definitions"
  intact "$id good" "$VCO3" "$L3_REL" "$WD3/$id-before"
}

# bad_checks <id> — check 3 names the definition no case uses; check 5 names the redefined
# helper export (the self-impl op, not the sourceRegex alone, decides); checks 1 and 4 pass.
bad_checks() {
  local id="$1"
  vce3 "$id" bad || return 0
  expect_check "$id bad" 1 PASS
  expect_check "$id bad" 3 FAIL
  detail_has "$id bad" 3 "$L3_LEFT"
  expect_check "$id bad" 4 PASS
  expect_check "$id bad" 5 FAIL
  detail_has "$id bad" 5 "harness-redef"
  detail_has "$id bad" 5 "$L3_REDEF"
  assert_eq "$id bad rc=$V_RC" "$id bad rc=1"
  intact "$id bad" "$VCO3" "$L3_REL" "$WD3/$id-before"
}

case_begin "pester-checks-1-to-5" "bin/verify-case-embed.sh"
all_checks pester
case_end

case_begin "pytest-checks-1-to-5" "bin/verify-case-embed.sh"
all_checks pytest
case_end

case_begin "js-checks-1-to-5" "bin/verify-case-embed.sh"
all_checks js
case_end

case_begin "pester-check3-check5-catch" "bin/verify-case-embed/checks.sh"
bad_checks pester
case_end

case_begin "pytest-check3-check5-catch" "bin/verify-case-embed/checks.sh"
bad_checks pytest
case_end

case_begin "js-check3-check5-catch" "bin/verify-case-embed/checks.sh"
bad_checks js
case_end
