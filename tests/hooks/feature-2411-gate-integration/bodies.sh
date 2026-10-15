# Tests: bin/check-case-markers.sh
# Single-path header keeps the dummy header lines in the fixtures below from being read as this file's own.
# Fixture test bodies for tests/hooks/feature-2411-gate-integration.sh (sourced by it): one
# body without case delimiters and one conforming body per language. Every body carries
# valid frontmatter and loads its helper library, so the marker gate is the only gate that
# can refuse it. Marker text lives only inside the heredoc bodies below.
# shellcheck shell=bash

cat > "$BODIES/sh-missing" <<'EOF'
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
source "$(dirname "$0")/../../tests/lib/harness.sh"
case_begin "a" "bin/a.sh"
echo a
case_end
case_begin "b" "bin/b.sh"
echo b
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
