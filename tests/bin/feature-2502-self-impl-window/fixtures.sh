# Fixture test files for tests/bin/feature-2502-self-impl-window.sh, written into $FXD.
# self.* carries every detection the language's self-impl op must report (line numbers pinned
# in the dispatcher); clean.* carries the look-alikes it must not report: a renamed counter or
# helper (the accepted limit), a counter or helper name inside a function or class, and a
# destructured import of the helper library's names.

mkdir -p "$FXD/tests/bin"

cat >"$FXD/tests/bin/self.Tests.ps1" <<'PS1'
BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
}
$script:PASS = 0
$Failed = 0
function Enter-HarnessIsolation { return 1 }
Describe 'x' -Tag 'target:bin/a.sh' {
    It 'y' { 1 | Should -Be 1 }
}
PS1

cat >"$FXD/tests/bin/clean.Tests.ps1" <<'PS1'
BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
}
$count = 0
function Enter-MyIsolation { return 1 }
Describe 'x' -Tag 'target:bin/a.sh' {
    It 'y' {
        $Passed = 0
        $Passed | Should -Be 0
    }
}
PS1

cat >"$FXD/tests/bin/test_self.py" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness  # noqa: E402,F401

PASS = 0
failed = 0


def isolate(tmp):
    return tmp


def _tl3_value():
    return "off"


def test_x():
    assert True
PY

cat >"$FXD/tests/bin/test_clean.py" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness  # noqa: E402,F401

count = 0


def my_isolate(tmp):
    passed = 0
    return tmp, passed


class Box:
    def isolate(self):
        return 1


def test_x():
    assert my_isolate(1) == (1, 0)
PY

cat >"$FXD/tests/bin/self.js" <<'JS'
"use strict";
const { test } = require("node:test");
const { caseBegin, caseEnd } = require("../lib/harness");

let PASS = 0;
var failed = 0;

function isolate() {
  return 1;
}

const gitInit = () => 0;

test("x", () => {});
JS

cat >"$FXD/tests/bin/clean.js" <<'JS'
"use strict";
const { test } = require("node:test");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

let passCount = 0;

function myIsolate() {
  let PASS = 0;
  return PASS;
}

test("x", () => {});
JS

cat >"$FXD/tests/bin/self.sh" <<'SH'
#!/usr/bin/env bash
set -u
source "$(dirname "$0")/../lib/harness.sh"
PASS=0
FAIL=0
pass() { echo ok; }
SH

cat >"$FXD/tests/bin/clean.sh" <<'SH'
#!/usr/bin/env bash
set -u
source "$(dirname "$0")/../lib/harness.sh"
COUNT=0
my_pass() { echo ok; }
SH

printf 'not a test\n' >"$FXD/tests/bin/notes.txt"
