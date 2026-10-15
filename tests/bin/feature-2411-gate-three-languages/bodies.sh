# Tests: bin/check-case-markers.sh
# Single-path header keeps the dummy header lines in the fixtures below from being read as this file's own.
# Fixture test bodies for tests/bin/feature-2411-gate-three-languages.sh (sourced by it).
# Marker text lives only inside the heredoc bodies below.
# shellcheck shell=bash

cat > "$BODIES/sh-missing" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: scope:common
echo no markers
EOF
cat > "$BODIES/sh-missing-three" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh, bin/c.sh
# Tags: scope:common
echo no markers
EOF
cat > "$BODIES/sh-missing-loads-helper" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: scope:common
source "$(dirname "$0")/../../tests/lib/harness.sh"
echo no markers
EOF
cat > "$BODIES/sh-conforming" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: scope:common
case_begin "a" "bin/a.sh"
echo a
case_end
case_begin "b" "bin/b.sh"
echo b
case_end
EOF
cat > "$BODIES/sh-grammar" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: scope:common
  case_begin "a" "bin/a.sh"
  case_end
EOF
cat > "$BODIES/sh-depth" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: scope:common
if true; then
case_begin "a" "bin/a.sh"
case_end
fi
EOF
cat > "$BODIES/sh-target" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: scope:common
case_begin "a" "/abs/a.sh"
case_end
EOF
cat > "$BODIES/sh-balance" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: scope:common
case_begin "a" "bin/a.sh"
echo never closed
EOF
cat > "$BODIES/sh-uncertain" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: scope:common
node -e '
for (const a of [1]) console.log(a)
'
case_begin "a" "bin/a.sh"
case_end
case_begin "b" "bin/b.sh"
case_end
EOF

cat > "$BODIES/pester-missing" <<'EOF'
# Tests: bin/a.ps1, bin/b.ps1
# Tags: scope:common
BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
}
Describe 'a' {
    It 'runs' { 1 | Should -Be 1 }
}
Describe 'b' {
    It 'runs' { 1 | Should -Be 1 }
}
EOF
cat > "$BODIES/pester-conforming" <<'EOF'
# Tests: bin/a.ps1, bin/b.ps1
# Tags: scope:common
BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
}
Describe 'a' -Tag 'target:bin/a.ps1' {
    It 'runs' { 1 | Should -Be 1 }
}
Describe 'b' -Tag 'target:bin/b.ps1' {
    It 'runs' { 1 | Should -Be 1 }
}
EOF
cat > "$BODIES/pester-malformed" <<'EOF'
# Tests: bin/a.ps1, bin/b.ps1
# Tags: scope:common
BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
}
Describe 'a' -Tag 'target:bin/a.ps1' {
    It 'runs' { 1 | Should -Be 1 }
}
Describe 'b' {
    It 'runs' { 1 | Should -Be 1 }
}
EOF
cat > "$BODIES/pester-noload" <<'EOF'
# Tests: bin/a.ps1, bin/b.ps1
# Tags: scope:common
Describe 'a' -Tag 'target:bin/a.ps1' {
    It 'runs' { 1 | Should -Be 1 }
}
Describe 'b' -Tag 'target:bin/b.ps1' {
    It 'runs' { 1 | Should -Be 1 }
}
EOF
cat > "$BODIES/pester-commentload" <<'EOF'
# Tests: bin/a.ps1, bin/b.ps1
# Tags: scope:common
# . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
Describe 'a' -Tag 'target:bin/a.ps1' {
    It 'runs' { 1 | Should -Be 1 }
}
Describe 'b' -Tag 'target:bin/b.ps1' {
    It 'runs' { 1 | Should -Be 1 }
}
EOF

cat > "$BODIES/pytest-missing" <<'EOF'
# Tests: bin/a.py, bin/b.py
# Tags: scope:common
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness
import pytest


def test_a():
    assert harness is not None


def test_b():
    assert pytest is not None
EOF
cat > "$BODIES/pytest-conforming" <<'EOF'
# Tests: bin/a.py, bin/b.py
# Tags: scope:common
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness
import pytest


@pytest.mark.target("bin/a.py")
def test_a():
    assert harness is not None


@pytest.mark.target("bin/b.py")
def test_b():
    assert True
EOF
cat > "$BODIES/pytest-malformed" <<'EOF'
# Tests: bin/a.py, bin/b.py
# Tags: scope:common
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness
import pytest


@pytest.mark.target("bin/a.py")
def test_a():
    assert harness is not None


def test_b():
    assert True
EOF
cat > "$BODIES/pytest-noload" <<'EOF'
# Tests: bin/a.py, bin/b.py
# Tags: scope:common
import pytest


@pytest.mark.target("bin/a.py")
def test_a():
    assert True


@pytest.mark.target("bin/b.py")
def test_b():
    assert True
EOF
cat > "$BODIES/pytest-commentload" <<'EOF'
# Tests: bin/a.py, bin/b.py
# Tags: scope:common
# import harness
import pytest


@pytest.mark.target("bin/a.py")
def test_a():
    assert True


@pytest.mark.target("bin/b.py")
def test_b():
    assert True
EOF

cat > "$BODIES/js-missing" <<'EOF'
// Tests: bin/a.js, bin/b.js
// Tags: scope:common
const harness = require("../lib/harness");

console.log(typeof harness);
EOF
cat > "$BODIES/js-conforming" <<'EOF'
// Tests: bin/a.js, bin/b.js
// Tags: scope:common
const { caseBegin, caseEnd } = require("../lib/harness");

caseBegin("a", "bin/a.js");
caseEnd();
caseBegin("b", "bin/b.js");
caseEnd();
EOF
cat > "$BODIES/js-malformed" <<'EOF'
// Tests: bin/a.js, bin/b.js
// Tags: scope:common
const { caseBegin, caseEnd } = require("../lib/harness");

caseBegin("a", "bin/a.js");
caseEnd();
caseBegin("b", "bin/b.js");
console.log("never closed");
EOF
cat > "$BODIES/js-uncertain" <<'EOF'
// Tests: bin/a.js, bin/b.js
// Tags: scope:common
const { caseBegin, caseEnd } = require("../lib/harness");

/*
caseBegin("old", "bin/a.js");
caseEnd();
*/
caseBegin("a", "bin/a.js");
caseEnd();
caseBegin("b", "bin/b.js");
caseEnd();
EOF
cat > "$BODIES/js-noload" <<'EOF'
// Tests: bin/a.js, bin/b.js
// Tags: scope:common
caseBegin("a", "bin/a.js");
caseEnd();
caseBegin("b", "bin/b.js");
caseEnd();
EOF
cat > "$BODIES/js-commentload" <<'EOF'
// Tests: bin/a.js, bin/b.js
// Tags: scope:common
// const { caseBegin, caseEnd } = require("../lib/harness");
caseBegin("a", "bin/a.js");
caseEnd();
caseBegin("b", "bin/b.js");
caseEnd();
EOF
