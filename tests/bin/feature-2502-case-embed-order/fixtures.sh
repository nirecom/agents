# Fixture test files and stub analyzers for tests/bin/feature-2502-case-embed-order.sh.
# Sourced by _lib.sh. Every language's sample has the same shape: three cases, where
# case 0 uses A, case 1 uses A, B and V, case 2 uses none, and U is used by no case.
#   A  a top-level function           B  a definition only case 1 uses
#   V  a top-level variable/constant  U  a top-level function no case uses
# The line numbers below are pinned in lang_info (_lib.sh).

cat >"$FXD/sample.Tests.ps1" <<'PS1'
BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
    function Get-Beta { return 2 }
}

function Get-Alpha { return 1 }

function Get-Unused { return 3 }

$Shared = 3

Describe 'alpha' -Tag 'target:bin/a.sh' {
    It 'uses alpha' {
        Get-Alpha | Should -Be 1
    }
}

Describe 'beta' -Tag 'target:bin/b.sh' {
    It 'uses alpha and beta' {
        (Get-Alpha) + (Get-Beta) | Should -Be $Shared
    }
}

Describe 'plain' -Tag 'target:bin/c.sh' {
    It 'uses nothing' {
        1 | Should -Be 1
    }
}
PS1

cat >"$FXD/test_sample.py" <<'PY'
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness  # noqa: E402,F401

LIMIT = 3


def helper_alpha():
    return 1


def helper_unused():
    return 9


@pytest.fixture
def beta_value():
    return 2


@pytest.mark.target("bin/a.sh")
def test_alpha():
    assert helper_alpha() == 1


@pytest.mark.target("bin/b.sh")
def test_beta(beta_value):
    assert helper_alpha() + beta_value == LIMIT


@pytest.mark.target("bin/c.sh")
def test_plain():
    assert True
PY

cat >"$FXD/sample.js" <<'JS'
"use strict";
const { test } = require("node:test");
const assert = require("node:assert");
const { caseBegin, caseEnd } = require("../lib/harness");

const LIMIT = 3;
let factor = 1;

function helperAlpha() {
  return 1;
}

function helperUnused() {
  return 9;
}

caseBegin("alpha", "bin/a.sh");
test("alpha", () => {
  assert.strictEqual(helperAlpha(), 1);
});
caseEnd();

caseBegin("beta", "bin/b.sh");
test("beta", () => {
  assert.strictEqual(helperAlpha() * factor + 2, LIMIT);
});
caseEnd();

caseBegin("plain", "bin/c.sh");
test("plain", () => {
  assert.ok(true);
});
caseEnd();
JS

# Stub analyzers: whatever the op, they answer with ORDER lines that disagree with the test
# case reader. STUB_ORDER=shift moves every range; STUB_ORDER=short reports case 0 only
# (with its true range). Both must make the deps op fail with rc 1.
cat >"$FXD/stub-analyzer.ps1" <<'PS1'
$t = "`t"
if ($env:STUB_ORDER -eq 'short') { $o = "ORDER${t}0${t}$($env:STUB_B0)${t}$($env:STUB_E0)`n" }
else { $o = "ORDER${t}0${t}90${t}99`nORDER${t}1${t}100${t}120`nORDER${t}2${t}130${t}140`n" }
$o += "0${t}`n1${t}`n2${t}`n"
if ($args[0] -eq 'all') { $o = "OP${t}deps`n" + $o }
[Console]::Out.Write($o)
exit 0
PS1

cat >"$FXD/stub-analyzer.py" <<'PY'
import os
import sys

if os.environ.get("STUB_ORDER") == "short":
    rows = [f"ORDER\t0\t{os.environ['STUB_B0']}\t{os.environ['STUB_E0']}"]
else:
    rows = ["ORDER\t0\t90\t99", "ORDER\t1\t100\t120", "ORDER\t2\t130\t140"]
sys.stdout.write("\n".join([*rows, "0\t", "1\t", "2\t"]) + "\n")
PY

cat >"$FXD/stub-analyzer.js" <<'JS'
"use strict";
const e = process.env;
const rows = e.STUB_ORDER === "short"
  ? [`ORDER\t0\t${e.STUB_B0}\t${e.STUB_E0}`]
  : ["ORDER\t0\t90\t99", "ORDER\t1\t100\t120", "ORDER\t2\t130\t140"];
process.stdout.write([...rows, "0\t", "1\t", "2\t"].join("\n") + "\n");
JS

# The launch-counting wrapper: one log line per analyzer start (its first argument, the op),
# then the real analyzer, kept beside it as pester-case-analyzer.real.ps1.
cat >"$FXD/count-analyzer.ps1" <<'PS1'
Add-Content -LiteralPath $env:CEA_LAUNCH_LOG -Value ([string]$args[0])
& (Join-Path $PSScriptRoot 'pester-case-analyzer.real.ps1') @args
exit $LASTEXITCODE
PS1
